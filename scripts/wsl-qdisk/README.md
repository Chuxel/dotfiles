# WSL qdisk

These scripts reproduce a directly mounted ext4 data disk for an Ubuntu WSL 2 distribution. Run them from **elevated Windows PowerShell**; UAC elevation is required to create and attach the VHDX and to manage the Scheduled Task.

## Defaults

| Setting | Default |
| --- | --- |
| Distribution | Default WSL distribution |
| VHDX directory | `Q:\WSL\Ubuntu` |
| Dynamic VHDX | `<VhdxDirectory>\qdisk.vhdx` |
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
  -VhdxDirectory 'D:\WSL-Data\Ubuntu' `
  -SizeGB 500 `
  -DiskLabel qdisk `
  -LinuxUser clantz `
  -MountPoint /home/clantz/Repos `
  -TaskName 'WSL Ubuntu qdisk mount'
```

When `-DistroName` is omitted, setup and uninstall use the current default shown by `wsl --list --verbose`. Pass `-DistroName` to target a different installed distribution.

`-VhdxDirectory` controls where `qdisk.vhdx` is stored. Use `-VhdxPath` instead when the file itself needs a different name; the two parameters are mutually exclusive:

```powershell
.\scripts\wsl-qdisk\setup.ps1 -VhdxPath 'D:\Virtual Disks\repos-data.vhdx'
```

The setup is idempotent. It creates an expandable VHDX only when the path is absent and formats only a newly attached, signature-free disk. It refuses to reformat an existing or ambiguous filesystem. A matching existing filesystem must be a whole-disk ext4 filesystem with the requested label.

The script also safely converts the former `/mnt/qdisk` mount plus `/home/clantz/Repos -> /mnt/qdisk` symlink layout. It refuses unrelated symlinks, mounts, or non-empty target directories.

## Boot flow

The installer registers an on-demand, highest-run-level Scheduled Task whose action is:

```text
C:\Windows\System32\wsl.exe --mount "Q:\WSL\Ubuntu\qdisk.vhdx" --vhd --bare
```

It installs the tracked `mount-qdisk.sh` template as `/usr/local/sbin/mount-qdisk` with LF line endings and mode `0755`. `/etc/wsl.conf` retains unrelated content, keeps `systemd=true`, and runs the helper from its `[boot]` command. If the filesystem UUID is not present, the helper starts the Windows task and waits up to 30 seconds. It discovers the device with `blkid`, which works even when WSL does not create `/dev/disk/by-label` links, then validates the ext4 label and captured UUID, creates the real mount-point directory, mounts the validated device, and assigns the filesystem root to the configured Linux user. UUID-based selection prevents a duplicate label from selecting an unrelated disk.

## Validate

This checks PowerShell parsing and, when `sh` or WSL is available, shell syntax:

```powershell
.\scripts\wsl-qdisk\validate.ps1
```

## Uninstall and data safety

Cleanup removes only marked configuration installed by these scripts, unmounts the filesystem, and detaches the VHDX. It does **not** remove the VHDX or its data by default:

```powershell
.\scripts\wsl-qdisk\uninstall.ps1 -VhdxDirectory 'D:\WSL-Data\Ubuntu'
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
