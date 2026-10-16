# Developer cache relocation

`setup.ps1` fills gaps in Windows developer cache configuration. It adopts working persistent settings already located off `C:` instead of replacing them with duplicate user-level values. Missing or `C:`-based caches default to `Q:\.tools`; that drive must remain available whenever the configured tools run.

## Configure

Run from a normal PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\devbox\dev-cache\setup.ps1
```

Use a different absolute fallback root when needed:

```powershell
.\devbox\dev-cache\setup.ps1 -CacheRoot 'D:\.tools'
```

`CacheRoot` is a fallback for caches that need relocation. It does not replace an effective cache already located on `Q:` or another non-system drive.

Setup also installs [Mr Boxington (`mbx`)](https://mr-boxington.jdx.dev/) when missing and enables its shared Rust build cache. Installing requires network access to GitHub Releases; an existing installation is reused without upgrading it.

Existing tool-cache contents are migrated by default when applying redirects:

```powershell
.\devbox\dev-cache\setup.ps1
```

Migration merges cache directories and de-duplicates identical files. When an interrupted migration leaves different versions of a cache file at both locations, the newer file wins; every copied file is hash-verified. Files locked by a running tool are reported and left at the source for a later run. Rerunning therefore converges safely instead of failing on cache entries updated or held open between runs.

Disable migration for a configuration-only run:

```powershell
.\devbox\dev-cache\setup.ps1 -MigrateExisting:$false
```

## Existing configuration and precedence

Windows builds a process environment from Machine values and then User values, so a User value normally shadows the same Machine variable. For each cache variable, the script:

1. Preserves an existing User value on `Q:` or another non-`C:` drive.
2. Otherwise preserves an existing Machine value on `Q:` or another non-`C:` drive without creating a duplicate User value.
3. Removes a `C:`-based User override when doing so exposes a working Machine value on the requested cache drive.
4. Creates a User value beneath `CacheRoot` only when the effective value is missing, relative, or `C:`-based.

The current PowerShell process receives the selected effective values immediately. New processes or a new sign-in are still required to receive all persistent environment and `PATH` changes.

The script broadcasts a Windows environment-change notification so applications that support it can refresh before launching new shells. Windows cannot mutate the environment of a PowerShell process that was already running. Restart an existing shell, or refresh Rust there explicitly:

```powershell
$env:RUSTUP_HOME = [Environment]::GetEnvironmentVariable('RUSTUP_HOME', 'User')
$env:CARGO_HOME = [Environment]::GetEnvironmentVariable('CARGO_HOME', 'User')
```

On the audited machine, the script adopts these existing Machine values unchanged:

| Variables | Existing location |
| --- | --- |
| `NPM_CONFIG_CACHE`, `NPM_CONFIG_PREFIX` | `Q:\.tools\.npm`, `Q:\.tools\.npm-global` |
| `NUGET_PACKAGES`, `NUGET_HTTP_CACHE_PATH`, `NUGET_PLUGINS_CACHE_PATH` | `Q:\.tools\.nuget\packages`, `Q:\.tools\.nuget\v3-cache`, `Q:\.tools\.nuget\plugins-cache` |
| `YARN_CACHE_FOLDER` | `Q:\.tools\.yarn` |

The Machine `PATH` entries for `Q:\.tools\dotnet` and `Q:\.tools\.npm-global` are preserved. Because the effective npm prefix is already on the Machine `PATH`, the script does not add another npm prefix or a duplicate User `PATH` entry.

## Fallback layout

On an unconfigured machine, the script creates only the directories needed for missing or `C:`-based variables:

| Ecosystem | Fallback variables |
| --- | --- |
| Windows and NuGet | `TEMP`, `TMP`, `NUGET_PACKAGES`, `NUGET_HTTP_CACHE_PATH`, `NUGET_PLUGINS_CACHE_PATH` |
| npm and JavaScript | `npm_config_cache`, `npm_config_prefix`, `YARN_CACHE_FOLDER`, `COREPACK_HOME`, `BUN_INSTALL_CACHE_DIR`, `DENO_DIR` |
| Browser tooling | `PLAYWRIGHT_BROWSERS_PATH`, `CYPRESS_CACHE_FOLDER`, `ELECTRON_CACHE`, `ELECTRON_BUILDER_CACHE` |
| PHP and Python | `COMPOSER_CACHE_DIR`, `PIP_CACHE_DIR`, `POETRY_CACHE_DIR`, `UV_CACHE_DIR` |
| Go, Java, and Rust | `GOCACHE`, `GOMODCACHE`, `GRADLE_USER_HOME`, `CARGO_HOME`, `RUSTUP_HOME`, `SCCACHE_DIR` |
| Native dependencies | `VCPKG_DEFAULT_BINARY_CACHE`, `VCPKG_DOWNLOADS` |

NuGet fallbacks use `<CacheRoot>\.nuget\packages`, `<CacheRoot>\.nuget\v3-cache`, and `<CacheRoot>\.nuget\plugins-cache`. npm uses `<CacheRoot>\.npm` and `<CacheRoot>\.npm-global`; these match the audited `Q:\.tools` layout. The effective npm global prefix is added to `PATH` only when no equivalent User or Machine entry exists.

When its effective cache is missing or `C:`-based, Yarn uses `<CacheRoot>\.yarn` and Composer uses `<CacheRoot>\composer`. These environment redirects are configured even when the corresponding command is not installed, so later installations inherit the relocated caches. Existing non-`C:` settings remain untouched.

Go's `GOBIN` remains at its default user-profile location, and `GOPATH` is unchanged. `CARGO_INSTALL_ROOT` keeps `cargo install` executables under `~\.cargo\bin` on `C:`, while Cargo caches and Rust toolchains use their selected relocated homes. Rust `target` directories may become mbx-managed when a build runs, as described below.

When Composer is installed, its global configuration is also synchronized with the effective `COMPOSER_CACHE_DIR`. Maven's `~/.m2/settings.xml` is updated safely with `localRepository`; unrelated XML content and namespaces are retained, and malformed or ambiguous XML is rejected without replacement.

When Rustup is installed, setup verifies that the selected `RUSTUP_HOME` exposes its installed toolchains and an active default before reporting success. If migration leaves no default, setup selects the exact already-installed `stable-*` toolchain when there is one, or the sole installed toolchain. Using the full installed name prevents a download. Ambiguous toolchain sets without one stable candidate still stop for explicit user choice.

## Mr Boxington build cache

On Windows x64 and ARM64, setup downloads the official prebuilt release, verifies its SHA-256 against the release's `SHA256SUMS`, and installs `mbx.exe` into `~\.cargo\bin`. No Cargo compilation, Rust toolchain download, or administrator access is required to install mbx itself; builds still require a working Rust toolchain and any native build tools the project needs.

Missing or system-drive cache settings use `<CacheRoot>\mbx` (`Q:\.tools\mbx` by default). Existing non-system `MBX_CACHE_DIR` User/Machine values retain the same precedence as other redirects. Without persistent environment overrides, setup preserves an existing non-system `cache_dir` in `%APPDATA%\mbx\config.toml`, or updates that setting with `mbx settings set cache_dir`. Unrelated mbx settings are retained. The action store lives in `mbx\actions`; managed targets default to `mbx\targets`, unless a separate `target.root` is already configured.

Setup runs `mbx setup --yes` to install its Cargo shim and configure rust-analyzer without replacing existing editor check settings. It prepends `%LOCALAPPDATA%\mbx\bin` to the User and current-process `PATH`, ahead of Rustup's Cargo, so ordinary `cargo build`, `cargo test`, and `cargo check` use mbx. If mise is active, mbx may also configure the recommended mise scope. Restart already-open shells and desktop applications to pick up the persistent `PATH` change. A Cargo executable earlier on the Machine `PATH` must be reordered there separately.

mbx and sccache cannot wrap the same Rust build. Setup no longer enables `RUSTC_WRAPPER=sccache` and removes that exact legacy User setting from earlier runs. Other persistent or process-level `RUSTC_WRAPPER` / `RUSTC_WORKSPACE_WRAPPER` settings stop setup with an actionable error rather than silently disabling mbx. Remove any conflicting `build.rustc-wrapper` / `build.rustc-workspace-wrapper` entries in Cargo configuration too; `mbx doctor` does not detect those. `SCCACHE_DIR` remains configured for other uses of sccache.

Existing mbx cache contents are **not** bulk-migrated, even with `-MigrateExisting`. Moving managed targets and their absolute links as ordinary cache files can break checkouts or running builds. Old data is left intact and a relocation starts with a cold cache; follow [mbx's target-placement guidance](https://mr-boxington.jdx.dev/managed-targets#change-target-placement) when moving existing managed targets. On Windows, managed targets require Developer Mode or appropriate privileges to create links; otherwise Cargo keeps its ordinary target directories. ReFS on the same volume permits cloned restores; NTFS uses copies.

After starting a new shell, inspect the effective setup:

```powershell
(Get-Command cargo).Source
mbx setup --status
mbx settings get cache_dir
mbx cache dir
mbx doctor
```

Cargo should resolve to the mbx shim (or an activated mise wrapper), and `mbx cache dir` should print the selected cache directory followed by `\actions`. To verify reuse rather than Cargo's own freshness checks, build the same workspace into two fresh target directories and inspect `mbx explain --last`.

## pnpm per-drive store

The script deliberately does **not** set pnpm `store-dir` or create `<CacheRoot>\pnpm`. With no explicit override, pnpm uses a store on the same drive as the project. On this machine, projects on `Q:` naturally use `Q:\.pnpm-store\v11`, while projects on `C:` use a `C:` store. This avoids cross-drive package linking and duplicate forced stores.

## Data safety

By default, setup moves contents from previous environment paths and known default tool-cache locations. Pass `-MigrateExisting:$false` to configure future cache use only. npm global-prefix contents and Rust toolchains are included. Cargo's `bin`, `.crates.toml`, and `.crates2.json` stay under the user profile so installed commands and their metadata remain on `C:`.

Internal cache junctions, such as Bun package aliases, and file symbolic links, such as links within Cargo git checkouts, are recreated beneath the new cache root. If an earlier migration materialized a directory alias as a physical directory, that cache-only alias copy is replaced after its canonical target is verified. Reparse points targeting outside the migrated cache are rejected.

Existing Windows `TEMP` and `TMP` contents are never bulk-moved because unrelated running processes may be using them; only future temporary files use the new location. The script does not redirect all of `AppData` and does not create junctions.

## Validate

Validation checks PowerShell parsing and isolated tests for Machine/User precedence, `PATH` behavior, missing and `C:`-based relocation, audited Machine-value preservation, mbx cache selection and verified installation, pnpm behavior, Rustup toolchain detection, safe migration/merge/collision handling, Cargo exclusions, and Maven XML creation and preservation. Installer tests use local archives without downloads or changes to installed tools. It runs PSScriptAnalyzer when installed:

```powershell
.\devbox\dev-cache\validate.ps1
```
