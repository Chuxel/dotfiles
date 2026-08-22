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
| npm and JavaScript | `npm_config_cache`, `npm_config_prefix`, `COREPACK_HOME`, `BUN_INSTALL_CACHE_DIR`, `DENO_DIR` |
| Browser tooling | `PLAYWRIGHT_BROWSERS_PATH`, `CYPRESS_CACHE_FOLDER`, `ELECTRON_CACHE`, `ELECTRON_BUILDER_CACHE` |
| Python | `PIP_CACHE_DIR`, `POETRY_CACHE_DIR`, `UV_CACHE_DIR` |
| Go, Java, and Rust | `GOCACHE`, `GOMODCACHE`, `GRADLE_USER_HOME`, `CARGO_HOME`, `RUSTUP_HOME`, `SCCACHE_DIR` |
| Native dependencies | `VCPKG_DEFAULT_BINARY_CACHE`, `VCPKG_DOWNLOADS` |

NuGet fallbacks use `<CacheRoot>\.nuget\packages`, `<CacheRoot>\.nuget\v3-cache`, and `<CacheRoot>\.nuget\plugins-cache`. npm uses `<CacheRoot>\.npm` and `<CacheRoot>\.npm-global`; these match the audited `Q:\.tools` layout. The effective npm global prefix is added to `PATH` only when no equivalent User or Machine entry exists.

When Yarn is installed and its effective cache is missing or `C:`-based, `YARN_CACHE_FOLDER` is set to `<CacheRoot>\.yarn`. If Yarn is absent, the script reports it as skipped and creates no Yarn directory. An existing non-`C:` Yarn setting remains untouched.

Go's `GOBIN` remains at its default user-profile location. `CARGO_INSTALL_ROOT` keeps `cargo install` executables under `~\.cargo\bin` on `C:`, while Cargo caches and Rust toolchains use their selected relocated homes. `GOPATH` and project-local Rust `target` directories are unchanged.

When `sccache` is installed, the script sets `RUSTC_WRAPPER=sccache`. Composer is configured through its command only when installed. Maven's `~/.m2/settings.xml` is updated safely with `localRepository`; unrelated XML content and namespaces are retained, and malformed or ambiguous XML is rejected without replacement.

When Rustup is installed, setup verifies that the selected `RUSTUP_HOME` exposes its installed toolchains and an active default before reporting success. If migration leaves no default, setup selects the exact already-installed `stable-*` toolchain when there is one, or the sole installed toolchain. Using the full installed name prevents a download. Ambiguous toolchain sets without one stable candidate still stop for explicit user choice.

## pnpm per-drive store

The script deliberately does **not** set pnpm `store-dir` or create `<CacheRoot>\pnpm`. With no explicit override, pnpm uses a store on the same drive as the project. On this machine, projects on `Q:` naturally use `Q:\.pnpm-store\v11`, while projects on `C:` use a `C:` store. This avoids cross-drive package linking and duplicate forced stores.

## Data safety

By default, setup moves contents from previous environment paths and known default tool-cache locations. Pass `-MigrateExisting:$false` to configure future cache use only. npm global-prefix contents and Rust toolchains are included. Cargo's `bin`, `.crates.toml`, and `.crates2.json` stay under the user profile so installed commands and their metadata remain on `C:`.

Internal cache junctions, such as Bun package aliases, are recreated to target the canonical directory beneath the new cache root. If an earlier migration materialized an alias as a physical directory, that cache-only alias copy is replaced after its canonical target is verified. Reparse points targeting outside the migrated cache are rejected.

Existing Windows `TEMP` and `TMP` contents are never bulk-moved because unrelated running processes may be using them; only future temporary files use the new location. The script does not redirect all of `AppData` and does not create junctions.

## Validate

Validation checks PowerShell parsing and isolated tests for Machine/User precedence, `PATH` behavior, missing and `C:`-based relocation, audited Machine-value preservation, pnpm behavior, Rustup toolchain detection, safe migration/merge/collision handling, Cargo exclusions, and Maven XML creation and preservation. It runs PSScriptAnalyzer when installed:

```powershell
.\devbox\dev-cache\validate.ps1
```
