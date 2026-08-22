# Move a WSL distribution

`move-wsl-distro.ps1` relocates an installed WSL distribution with modern WSL's
native `wsl.exe --manage <distro> --move <location>` command. It never exports,
unregisters, imports, edits the WSL registry, or manipulates VHDX files directly.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell on Windows.
- A current Microsoft Store version of WSL that supports `--manage ... --move`.
  Run `wsl.exe --update` if the script reports that the operation is unsupported.
- The destination drive must be mounted and available as a filesystem drive.
- Close applications using the selected distribution. The distribution is
  unavailable from termination until the native move finishes.

## Usage

The destination is always `<drive>:\.wsl\<distribution-name>`. When no
distribution is specified, the script uses the default distribution returned
first by `wsl.exe --list --quiet`. The drive defaults to `Q:`.

```powershell
# Move the default distribution to Q:\.wsl\<default-distribution>
.\devbox\wsl-move\move-wsl-distro.ps1

# Preview only; does not terminate or move Ubuntu
.\devbox\wsl-move\move-wsl-distro.ps1 Ubuntu -WhatIf

# Move Ubuntu to Q:\.wsl\Ubuntu
.\devbox\wsl-move\move-wsl-distro.ps1 Ubuntu

# Move Ubuntu-24.04 to D:\.wsl\Ubuntu-24.04
.\devbox\wsl-move\move-wsl-distro.ps1 Ubuntu-24.04 -DestinationDrive D:

# Move the default distribution to D:\.wsl\<default-distribution>
.\devbox\wsl-move\move-wsl-distro.ps1 -DestinationDrive D:
```

The operation has high confirmation impact, so normal PowerShell confirmation
semantics apply. Use `-Confirm:$false` only when an unattended move is intended.
The script terminates only the selected distribution; it does not run
`wsl.exe --shutdown`.

Before confirmation, the script verifies the exact installed distribution name,
the destination drive and `WSL` root, path safety, destination availability, and
native move support. Existing destination paths are rejected, including empty
directories. WSL provides no supported location query, so the script does not
guess that an occupied directory is the distribution's current location.

After a successful move, start and verify the distribution:

```powershell
wsl.exe -d Ubuntu
```

If WSL reports a move failure, the script surfaces the command error and does
not unregister the distribution or remove original data. The selected distro
remains terminated; resolve the WSL error and start it again with
`wsl.exe -d <name>`. A newly created `<drive>:\.wsl` parent directory may remain.

## Validation

Validation parses every PowerShell file and uses mocked WSL output to exercise
path construction, invalid names, UTF-16 NUL cleanup, distro matching, and
feature detection. It never invokes `wsl.exe` or moves an installed distribution.

```powershell
.\devbox\wsl-move\validate.ps1
```
