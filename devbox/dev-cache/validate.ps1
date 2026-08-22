<# Validates the developer cache PowerShell scripts. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$powerShellFiles = @(
    (Join-Path $PSScriptRoot 'setup.ps1'),
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

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

if (-not $failed) {
    $tokens = $null
    $errors = $null
    $setupAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'setup.ps1'),
        [ref]$tokens,
        [ref]$errors)
    $testFunctionNames = @(
        'Get-PathDriveRoot',
        'Resolve-EnvironmentRedirect',
        'Test-PathListContains',
        'Get-InstalledRustupToolchains',
        'Select-RustupDefaultCandidate',
        'Resolve-ReparseTarget',
        'Get-MappedReparseTarget',
        'Get-MigrationItems',
        'Assert-DirectoryMigrationCompatible',
        'Move-DirectoryContents',
        'Set-MavenLocalRepository'
    )
    foreach ($functionName in $testFunctionNames) {
        $functionAst = $setupAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)
        if ($null -eq $functionAst) {
            throw "Could not find function under test: $functionName"
        }
        Invoke-Expression $functionAst.Extent.Text
    }

    $systemRoot = 'C:\'
    $machinePlan = Resolve-EnvironmentRedirect `
        -Name 'NPM_CONFIG_CACHE' `
        -UserValue $null `
        -MachineValue 'Q:\.tools\.npm' `
        -DesiredValue 'Q:\.tools\.npm' `
        -SystemDriveRoot $systemRoot
    Assert-Equal $machinePlan.Action 'PreserveMachine' 'A Q:-based machine value must not gain a user override.'
    Assert-Equal $machinePlan.EffectiveValue 'Q:\.tools\.npm' 'The machine npm cache must remain effective.'

    $userPlan = Resolve-EnvironmentRedirect `
        -Name 'YARN_CACHE_FOLDER' `
        -UserValue 'Q:\UserCaches\yarn' `
        -MachineValue 'Q:\.tools\.yarn' `
        -DesiredValue 'Q:\.tools\.yarn' `
        -SystemDriveRoot $systemRoot
    Assert-Equal $userPlan.Action 'PreserveUser' 'An existing non-system User value must retain precedence.'
    Assert-Equal $userPlan.EffectiveValue 'Q:\UserCaches\yarn' 'The existing User value must remain effective.'

    $staleUserPlan = Resolve-EnvironmentRedirect `
        -Name 'NUGET_PACKAGES' `
        -UserValue 'C:\Users\Test\.nuget\packages' `
        -MachineValue 'Q:\.tools\.nuget\packages' `
        -DesiredValue 'Q:\.tools\.nuget\packages' `
        -SystemDriveRoot $systemRoot
    Assert-Equal $staleUserPlan.Action 'RemoveUser' 'A C:-based user value should expose an existing Q:-based machine value.'
    Assert-Equal $staleUserPlan.EffectiveValue 'Q:\.tools\.nuget\packages' 'The Q:-based machine value must be adopted.'

    $missingPlan = Resolve-EnvironmentRedirect `
        -Name 'YARN_CACHE_FOLDER' `
        -UserValue $null `
        -MachineValue $null `
        -DesiredValue 'Q:\.tools\.yarn' `
        -SystemDriveRoot $systemRoot
    Assert-Equal $missingPlan.Action 'SetUser' 'A missing cache redirect must be created for an unconfigured machine.'

    $cDrivePlan = Resolve-EnvironmentRedirect `
        -Name 'NUGET_HTTP_CACHE_PATH' `
        -UserValue $null `
        -MachineValue 'C:\Users\Test\AppData\Local\NuGet\v3-cache' `
        -DesiredValue 'Q:\.tools\.nuget\v3-cache' `
        -SystemDriveRoot $systemRoot
    Assert-Equal $cDrivePlan.Action 'SetUser' 'An effective C:-based cache must be redirected.'

    $machinePath = 'Q:\.tools\dotnet;Q:\.tools\.npm-global'
    Assert-True `
        (Test-PathListContains -PathValues @($null, $machinePath) -Directory 'Q:\.tools\.npm-global\') `
        'A machine PATH entry must prevent a duplicate user PATH entry.'
    Assert-True `
        (-not (Test-PathListContains -PathValues @($null, $machinePath) -Directory 'D:\.tools\.npm-global')) `
        'A missing PATH directory must be detected.'

    $auditValues = [ordered]@{
        NPM_CONFIG_CACHE          = 'Q:\.tools\.npm'
        NPM_CONFIG_PREFIX         = 'Q:\.tools\.npm-global'
        NUGET_PACKAGES            = 'Q:\.tools\.nuget\packages\'
        NUGET_HTTP_CACHE_PATH     = 'Q:\.tools\.nuget\v3-cache'
        NUGET_PLUGINS_CACHE_PATH  = 'Q:\.tools\.nuget\plugins-cache'
        YARN_CACHE_FOLDER         = 'Q:\.tools\.yarn'
    }
    foreach ($entry in $auditValues.GetEnumerator()) {
        $auditPlan = Resolve-EnvironmentRedirect `
            -Name $entry.Key `
            -UserValue $null `
            -MachineValue $entry.Value `
            -DesiredValue ([IO.Path]::Combine('D:\.tools', $entry.Key)) `
            -SystemDriveRoot $systemRoot
        Assert-Equal $auditPlan.Action 'PreserveMachine' "$($entry.Key) should preserve the audited machine value."
        Assert-True ($auditPlan.EffectiveValue -notlike 'D:\.tools\*') "$($entry.Key) must not create a duplicate fallback directory."
    }

    $setupContent = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'setup.ps1'))
    Assert-True ($setupContent -notmatch 'store-dir') 'setup.ps1 must not configure pnpm store-dir.'
    Assert-True ($setupContent -notmatch 'Join-Path\s+\$CacheRoot\s+[''"]pnpm[''"]') 'setup.ps1 must not create a pnpm cache directory.'
    Assert-True ($setupContent -notmatch 'rustup\s+default\s+stable') 'setup.ps1 must not download or select a Rust toolchain automatically.'

    $rustToolchains = @(
        Get-InstalledRustupToolchains -Output @(
            'stable-x86_64-pc-windows-msvc (active, default)',
            'nightly-x86_64-pc-windows-msvc'
        )
    )
    Assert-Equal $rustToolchains.Count 2 'Installed Rustup toolchains must be recognized.'
    Assert-Equal $rustToolchains[0] `
        'stable-x86_64-pc-windows-msvc (active, default)' `
        'Rustup toolchain details must remain intact.'
    Assert-Equal `
        @(Get-InstalledRustupToolchains -Output @('no installed toolchains')).Count `
        0 `
        'Rustup no-toolchains output must not be treated as an installed toolchain.'
    Assert-Equal `
        (Select-RustupDefaultCandidate -Toolchains $rustToolchains) `
        'stable-x86_64-pc-windows-msvc' `
        'An exact installed stable toolchain must be selected as the default candidate.'
    Assert-Equal `
        (Select-RustupDefaultCandidate -Toolchains @('1.94.0-x86_64-pc-windows-msvc')) `
        '1.94.0-x86_64-pc-windows-msvc' `
        'A sole installed toolchain must be selected as the default candidate.'
    Assert-Equal `
        (Select-RustupDefaultCandidate -Toolchains @(
            'nightly-2026-04-14-x86_64-pc-windows-msvc',
            '1.94.0-x86_64-pc-windows-msvc'
        )) `
        $null `
        'Multiple installed toolchains without stable must require explicit choice.'

    $migrationTestRoot = Join-Path ([IO.Path]::GetTempPath()) "dev-cache-migration-$([Guid]::NewGuid().ToString('N'))"
    try {
        $source = Join-Path $migrationTestRoot 'source'
        $destination = Join-Path $migrationTestRoot 'destination'
        New-Item -ItemType Directory -Path (Join-Path $source 'nested') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $destination 'nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'unique.txt'), 'move me')
        [IO.File]::SetAttributes(
            (Join-Path $source 'unique.txt'),
            [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly)
        [IO.File]::WriteAllText((Join-Path $source 'nested\same.txt'), 'same')
        [IO.File]::WriteAllText((Join-Path $destination 'nested\same.txt'), 'same')
        Move-DirectoryContents -Source $source -Destination $destination
        Assert-True (-not (Test-Path -LiteralPath $source)) 'A fully migrated source directory must be removed.'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'unique.txt'))) 'move me' 'Unique files must move.'
        $migratedAttributes = [IO.File]::GetAttributes((Join-Path $destination 'unique.txt'))
        Assert-True `
            (($migratedAttributes -band [IO.FileAttributes]::Hidden) -ne 0) `
            'Migrated files must preserve hidden attributes.'
        Assert-True `
            (($migratedAttributes -band [IO.FileAttributes]::ReadOnly) -ne 0) `
            'Migrated files must preserve read-only attributes.'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'nested\same.txt'))) 'same' 'Identical files must merge safely.'

        $collisionSource = Join-Path $migrationTestRoot 'collision-source'
        $collisionDestination = Join-Path $migrationTestRoot 'collision-destination'
        New-Item -ItemType Directory -Path $collisionSource, $collisionDestination -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $collisionSource 'conflict.txt'), 'source')
        [IO.File]::WriteAllText((Join-Path $collisionDestination 'conflict.txt'), 'destination')
        [IO.File]::WriteAllText((Join-Path $collisionSource 'must-remain.txt'), 'not partially moved')
        $collisionRejected = $false
        try {
            Move-DirectoryContents -Source $collisionSource -Destination $collisionDestination
        }
        catch {
            $collisionRejected = $true
        }
        Assert-True $collisionRejected 'Different destination content must stop migration.'
        Assert-True (Test-Path -LiteralPath (Join-Path $collisionSource 'must-remain.txt')) 'Collision preflight must prevent partial moves.'

        $resumableSource = Join-Path $migrationTestRoot 'resumable-source'
        $resumableDestination = Join-Path $migrationTestRoot 'resumable-destination'
        New-Item -ItemType Directory -Path $resumableSource, $resumableDestination -Force | Out-Null
        $resumableSourceFile = Join-Path $resumableSource 'cache.bin'
        $resumableDestinationFile = Join-Path $resumableDestination 'cache.bin'
        [IO.File]::WriteAllText($resumableSourceFile, 'newer source')
        [IO.File]::WriteAllText($resumableDestinationFile, 'older destination')
        [IO.File]::SetLastWriteTimeUtc($resumableDestinationFile, [DateTime]::UtcNow.AddMinutes(-2))
        [IO.File]::SetLastWriteTimeUtc($resumableSourceFile, [DateTime]::UtcNow.AddMinutes(-1))
        Move-DirectoryContents `
            -Source $resumableSource `
            -Destination $resumableDestination `
            -ResolveCacheConflicts
        Assert-Equal `
            ([IO.File]::ReadAllText($resumableDestinationFile)) `
            'newer source' `
            'A newer source cache file must replace an older destination file.'

        New-Item -ItemType Directory -Path $resumableSource -Force | Out-Null
        [IO.File]::WriteAllText($resumableSourceFile, 'older source')
        [IO.File]::SetLastWriteTimeUtc($resumableSourceFile, [DateTime]::UtcNow.AddMinutes(-2))
        [IO.File]::SetLastWriteTimeUtc($resumableDestinationFile, [DateTime]::UtcNow.AddMinutes(-1))
        Move-DirectoryContents `
            -Source $resumableSource `
            -Destination $resumableDestination `
            -ResolveCacheConflicts
        Assert-Equal `
            ([IO.File]::ReadAllText($resumableDestinationFile)) `
            'newer source' `
            'A newer destination cache file must be retained.'

        $lockedSource = Join-Path $migrationTestRoot 'locked-source'
        $lockedDestination = Join-Path $migrationTestRoot 'locked-destination'
        New-Item -ItemType Directory -Path $lockedSource, $lockedDestination -Force | Out-Null
        $lockedSourceFile = Join-Path $lockedSource 'cache.db'
        $lockedDestinationFile = Join-Path $lockedDestination 'cache.db'
        [IO.File]::WriteAllText($lockedSourceFile, 'in use')
        [IO.File]::WriteAllText($lockedDestinationFile, 'older')
        [IO.File]::SetLastWriteTimeUtc($lockedDestinationFile, [DateTime]::UtcNow.AddMinutes(-2))
        [IO.File]::SetLastWriteTimeUtc($lockedSourceFile, [DateTime]::UtcNow.AddMinutes(-1))
        $lockedStream = [IO.File]::Open(
            $lockedSourceFile,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        try {
            Move-DirectoryContents `
                -Source $lockedSource `
                -Destination $lockedDestination `
                -ResolveCacheConflicts
            Assert-True `
                (Test-Path -LiteralPath $lockedSourceFile) `
                'A locked cache file must remain for a later migration run.'
        }
        finally {
            $lockedStream.Dispose()
        }

        $freshLockedSource = Join-Path $migrationTestRoot 'fresh-locked-source'
        $freshLockedDestination = Join-Path $migrationTestRoot 'fresh-locked-destination'
        New-Item -ItemType Directory -Path $freshLockedSource -Force | Out-Null
        $freshLockedSourceFile = Join-Path $freshLockedSource 'cache.db'
        $freshLockedDestinationFile = Join-Path $freshLockedDestination 'cache.db'
        [IO.File]::WriteAllText($freshLockedSourceFile, 'in use')
        $freshLockedStream = [IO.File]::Open(
            $freshLockedSourceFile,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        try {
            Move-DirectoryContents `
                -Source $freshLockedSource `
                -Destination $freshLockedDestination `
                -ResolveCacheConflicts
            Assert-True `
                (Test-Path -LiteralPath $freshLockedSourceFile) `
                'A fresh locked cache file must remain for a later migration run.'
            Assert-True `
                (-not (Test-Path -LiteralPath $freshLockedDestinationFile)) `
                'A failed fresh copy must not leave a partial destination file.'
        }
        finally {
            $freshLockedStream.Dispose()
        }

        $cargoSource = Join-Path $migrationTestRoot 'cargo-source'
        $cargoDestination = Join-Path $migrationTestRoot 'cargo-destination'
        New-Item -ItemType Directory -Path (Join-Path $cargoSource 'bin') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $cargoSource 'registry') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $cargoSource 'bin\tool.exe'), 'tool')
        [IO.File]::WriteAllText((Join-Path $cargoSource '.crates.toml'), 'metadata')
        [IO.File]::WriteAllText((Join-Path $cargoSource 'registry\cache.bin'), 'cache')
        Move-DirectoryContents `
            -Source $cargoSource `
            -Destination $cargoDestination `
            -ExcludeNames @('bin', '.crates.toml', '.crates2.json')
        Assert-True (Test-Path -LiteralPath (Join-Path $cargoSource 'bin\tool.exe')) 'Cargo binaries must remain in place.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cargoSource '.crates.toml')) 'Cargo install metadata must remain in place.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cargoDestination 'registry\cache.bin')) 'Cargo cache contents must migrate.'

        $junctionSource = Join-Path $migrationTestRoot 'junction-source'
        $junctionDestination = Join-Path $migrationTestRoot 'junction-destination'
        $canonicalSource = Join-Path $junctionSource 'package@1.0.0'
        $aliasSource = Join-Path $junctionSource 'package\1.0.0'
        $canonicalDestination = Join-Path $junctionDestination 'package@1.0.0'
        $aliasDestination = Join-Path $junctionDestination 'package\1.0.0'
        New-Item -ItemType Directory -Path $canonicalSource -Force | Out-Null
        New-Item -ItemType Directory -Path $aliasDestination -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $canonicalSource 'package.json'), '{"name":"package"}')
        [IO.File]::WriteAllText((Join-Path $aliasDestination 'package.json'), '{"name":"package"}')
        New-Item -ItemType Junction -Path $aliasSource -Target $canonicalSource -Force | Out-Null
        Move-DirectoryContents -Source $junctionSource -Destination $junctionDestination
        $migratedAlias = Get-Item -LiteralPath $aliasDestination -Force
        Assert-True `
            (($migratedAlias.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
            'An internal cache junction must remain a junction after migration.'
        Assert-Equal `
            ([IO.Path]::GetFullPath(@($migratedAlias.Target)[0]).TrimEnd('\')) `
            ([IO.Path]::GetFullPath($canonicalDestination).TrimEnd('\')) `
            'An internal cache junction must target the migrated canonical directory.'
        Assert-True `
            (Test-Path -LiteralPath (Join-Path $aliasDestination 'package.json')) `
            'A migrated internal cache junction must resolve package content.'

        $relativeTargetSource = Join-Path $junctionSource 'skills-real'
        $relativeLinkSource = Join-Path $junctionSource '.claude\skills'
        New-Item -ItemType Directory -Path $relativeTargetSource -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $relativeTargetSource 'SKILL.md'), 'skill')
        New-Item `
            -ItemType SymbolicLink `
            -Path $relativeLinkSource `
            -Target '..\skills-real' `
            -Force | Out-Null
        Move-DirectoryContents -Source $junctionSource -Destination $junctionDestination
        $relativeLinkDestination = Join-Path $junctionDestination '.claude\skills'
        $migratedRelativeLink = Get-Item -LiteralPath $relativeLinkDestination -Force
        Assert-Equal $migratedRelativeLink.LinkType 'SymbolicLink' 'Relative symbolic links must remain symbolic links.'
        Assert-Equal @($migratedRelativeLink.Target)[0] '..\skills-real' 'Relative symbolic-link targets must remain relative.'
        Assert-True `
            (Test-Path -LiteralPath (Join-Path $relativeLinkDestination 'SKILL.md')) `
            'A migrated relative symbolic link must resolve within the destination cache.'

        $externalTarget = Join-Path $migrationTestRoot 'external-target'
        $externalSource = Join-Path $migrationTestRoot 'external-source'
        $externalDestination = Join-Path $migrationTestRoot 'external-destination'
        New-Item -ItemType Directory -Path $externalTarget, $externalSource -Force | Out-Null
        New-Item `
            -ItemType Junction `
            -Path (Join-Path $externalSource 'external') `
            -Target $externalTarget | Out-Null
        $externalRejected = $false
        try {
            Move-DirectoryContents -Source $externalSource -Destination $externalDestination
        }
        catch {
            $externalRejected = $true
        }
        Assert-True $externalRejected 'External reparse-point targets must be rejected.'
    }
    finally {
        if (Test-Path -LiteralPath $migrationTestRoot) {
            Remove-Item -LiteralPath $migrationTestRoot -Recurse -Force
        }
    }

    $mavenTestRoot = Join-Path ([IO.Path]::GetTempPath()) "dev-cache-maven-$([Guid]::NewGuid().ToString('N'))"
    try {
        $mavenDirectory = Join-Path $mavenTestRoot '.m2'
        New-Item -ItemType Directory -Path $mavenDirectory -Force | Out-Null
        $settingsPath = Join-Path $mavenDirectory 'settings.xml'
        Set-MavenLocalRepository -RepositoryPath 'Q:\.tools\maven' -MavenDirectory $mavenDirectory

        $createdDocument = [Xml.XmlDocument]::new()
        $createdDocument.Load($settingsPath)
        Assert-Equal $createdDocument.DocumentElement.LocalName 'settings' 'Maven settings must have a settings root.'
        Assert-Equal $createdDocument.DocumentElement.NamespaceURI `
            'http://maven.apache.org/SETTINGS/1.0.0' `
            'Maven settings must use the Maven namespace.'
        $createdRepository = @(
            $createdDocument.DocumentElement.ChildNodes |
                Where-Object { $_ -is [Xml.XmlElement] -and $_.LocalName -eq 'localRepository' }
        )
        Assert-Equal $createdRepository.Count 1 'Maven settings must contain one localRepository.'
        Assert-Equal $createdRepository[0].InnerText 'Q:\.tools\maven' 'Maven localRepository must use the cache root.'

        $existingXml = @'
<?xml version="1.0" encoding="utf-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <!-- preserve this comment -->
  <mirrors><mirror><id>preserve-me</id></mirror></mirrors>
  <localRepository>C:\Users\Test\.m2\repository</localRepository>
</settings>
'@
        [IO.File]::WriteAllText($settingsPath, $existingXml)
        Set-MavenLocalRepository -RepositoryPath 'Q:\.tools\maven' -MavenDirectory $mavenDirectory
        $updatedDocument = [Xml.XmlDocument]::new()
        $updatedDocument.Load($settingsPath)
        Assert-True ($updatedDocument.OuterXml -match 'preserve this comment') 'Maven comments must be preserved.'
        Assert-True ($updatedDocument.OuterXml -match 'preserve-me') 'Unrelated Maven elements must be preserved.'
        $updatedRepository = @(
            $updatedDocument.DocumentElement.ChildNodes |
                Where-Object { $_ -is [Xml.XmlElement] -and $_.LocalName -eq 'localRepository' }
        )
        Assert-Equal $updatedRepository[0].InnerText 'Q:\.tools\maven' 'Existing Maven localRepository must be updated.'

        [IO.File]::WriteAllText($settingsPath, '<settings><broken></settings>')
        $malformedBefore = [IO.File]::ReadAllText($settingsPath)
        $malformedRejected = $false
        try {
            Set-MavenLocalRepository -RepositoryPath 'Q:\.tools\maven' -MavenDirectory $mavenDirectory
        }
        catch {
            $malformedRejected = $true
        }
        Assert-True $malformedRejected 'Malformed Maven XML must be rejected.'
        Assert-Equal ([IO.File]::ReadAllText($settingsPath)) $malformedBefore 'Malformed Maven XML must remain unchanged.'
    }
    finally {
        if (Test-Path -LiteralPath $mavenTestRoot) {
            Remove-Item -LiteralPath $mavenTestRoot -Recurse -Force
        }
    }
}

$scriptAnalyzer = Get-Command 'Invoke-ScriptAnalyzer' -ErrorAction SilentlyContinue
if ($scriptAnalyzer) {
    $analysisResults = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse)
    if ($analysisResults.Count -gt 0) {
        $failed = $true
        $analysisResults | Format-Table -AutoSize | Out-Host
    }
}
else {
    Write-Warning 'PSScriptAnalyzer is not installed; static analysis was skipped.'
}

if ($failed) {
    throw 'Validation failed.'
}

Write-Host 'PowerShell parsing, redirect behavior, and available static analysis checks passed.' -ForegroundColor Green
