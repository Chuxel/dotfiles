# WSL qdisk

These scripts reproduce a directly mounted ext4 data disk for an Ubuntu WSL 2 distribution. Run them from **elevated Windows PowerShell**; UAC elevation is required to create and attach the VHDX and to manage the Scheduled Task.

## Defaults

| Setting | Default |
| --- | --- |
| Distribution | `Ubuntu` |
| Dynamic VHDX | `Q:\WSL\Ubuntu\qdisk.vhdx` |
| Maximum size | 500 GB |
| Filesystem | ext4, label `qdisk` |
| Linux user | `clantz` |
| Direct mount point | `/home/clantz/Repos` |
| Scheduled Task | `WSL Ubuntu qdisk mount` |

Requirements are Windows 11 (or a current Windows 10 WSL release) with `wsl --mount` support, an installed Ubuntu WSL 2 distribution, Windows drive `Q:` (for the default path), and standard Ubuntu disk tools (`blkid`, `findmnt`, `lsblk`, `mkfs.ext4`, and `wipefs`).

## Install

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\wsl-qdisk\setup.ps1
```

All settings can be overridden:

```powershell
.\scripts\wsl-qdisk\setup.ps1 `
  -DistroName Ubuntu `
  -VhdxPath 'Q:\WSL\Ubuntu\qdisk.vhdx' `
  -SizeGB 500 `
  -DiskLabel qdisk `
  -LinuxUser clantz `
  -MountPoint /home/clantz/Repos `
  -TaskName 'WSL Ubuntu qdisk mount'
```

The setup is idempotent. It creates an expandable VHDX only when the path is absent and formats only a newly attached, signature-free disk. It refuses to reformat an existing or ambiguous filesystem. A matching existing filesystem must be a whole-disk ext4 filesystem with the requested label.

The script also safely converts the former `/mnt/qdisk` mount plus `/home/clantz/Repos -> /mnt/qdisk` symlink layout. It refuses unrelated symlinks, mounts, or non-empty target directories.

## Boot flow

The installer registers an on-demand, highest-run-level Scheduled Task whose action is:

```text
C:\Windows\System32\wsl.exe --mount "Q:\WSL\Ubuntu\qdisk.vhdx" --vhd --bare
```

It installs the tracked `mount-qdisk.sh` template as `/usr/local/sbin/mount-qdisk` with LF line endings and mode `0755`. `/etc/wsl.conf` retains unrelated content, keeps `systemd=true`, and runs the helper from its `[boot]` command. If the label is not present, the helper starts the Windows task and waits up to 30 seconds. It validates the ext4 label and the filesystem UUID captured during setup, creates the real mount-point directory, mounts the validated `/dev/disk/by-label/qdisk` device, and assigns the filesystem root to the configured Linux user. A duplicate label therefore fails safely instead of selecting an unrelated disk.

## Validate

This checks PowerShell parsing and, when `sh` or WSL is available, shell syntax:

```powershell
.\scripts\wsl-qdisk\validate.ps1
```

## Uninstall and data safety

Cleanup removes only marked configuration installed by these scripts, unmounts the filesystem, and detaches the VHDX. It does **not** remove the VHDX or its data by default:

```powershell
.\scripts\wsl-qdisk\uninstall.ps1
```

Permanent deletion requires both a destructive switch and an exact, case-sensitive confirmation:

```powershell
.\scripts\wsl-qdisk\uninstall.ps1 `
  -DeleteVhdx `
  -ConfirmVhdxDeletion 'DELETE Q:\WSL\Ubuntu\qdisk.vhdx'
```

## Recovery

Attach the existing disk manually from elevated PowerShell, then run the helper in Ubuntu:

```powershell
wsl.exe --mount 'Q:\WSL\Ubuntu\qdisk.vhdx' --vhd --bare
wsl.exe -d Ubuntu -u root -- /usr/local/sbin/mount-qdisk
```

Inspect or detach it without deleting data:

```powershell
wsl.exe -d Ubuntu -- findmnt /home/clantz/Repos
wsl.exe --unmount 'Q:\WSL\Ubuntu\qdisk.vhdx'
```
