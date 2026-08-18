#!/bin/sh
# Managed by chuxel/dotfiles scripts/wsl-qdisk.
set -eu

disk_label=__DISK_LABEL__
filesystem_uuid=__FILESYSTEM_UUID__
linux_user=__LINUX_USER__
mount_point=__MOUNT_POINT__
task_name=__TASK_NAME__
device="/dev/disk/by-label/$disk_label"

if [ ! -e "$device" ]; then
    /mnt/c/Windows/System32/schtasks.exe /Run /TN "$task_name" >/dev/null

    remaining=30
    while [ "$remaining" -gt 0 ] && [ ! -e "$device" ]; do
        sleep 1
        remaining=$((remaining - 1))
    done
fi

if [ ! -b "$device" ]; then
    echo "qdisk: block device $device did not appear within 30 seconds" >&2
    exit 1
fi

filesystem_type="$(blkid -s TYPE -o value -- "$device")"
actual_label="$(blkid -s LABEL -o value -- "$device")"
actual_uuid="$(blkid -s UUID -o value -- "$device")"
if [ "$filesystem_type" != "ext4" ] ||
    [ "$actual_label" != "$disk_label" ] ||
    [ "$actual_uuid" != "$filesystem_uuid" ]; then
    echo "qdisk: $device does not match the configured ext4 filesystem" >&2
    exit 1
fi

if ! id "$linux_user" >/dev/null 2>&1; then
    echo "qdisk: Linux user '$linux_user' does not exist" >&2
    exit 1
fi
primary_group="$(id -gn "$linux_user")"

if [ -L "$mount_point" ]; then
    echo "qdisk: refusing to mount over symlink $mount_point" >&2
    exit 1
fi

if [ -e "$mount_point" ] && [ ! -d "$mount_point" ]; then
    echo "qdisk: mount target $mount_point is not a directory" >&2
    exit 1
fi

mkdir -p -- "$mount_point"

if mountpoint -q -- "$mount_point"; then
    mounted_device="$(findmnt -rn -M "$mount_point" -o SOURCE)"
    mounted_type="$(findmnt -rn -M "$mount_point" -o FSTYPE)"
    mounted_label="$(blkid -s LABEL -o value -- "$mounted_device")"
    mounted_uuid="$(blkid -s UUID -o value -- "$mounted_device")"
    if [ "$mounted_type" != "ext4" ] ||
        [ "$mounted_label" != "$disk_label" ] ||
        [ "$mounted_uuid" != "$filesystem_uuid" ]; then
        echo "qdisk: $mount_point is occupied by an unexpected filesystem" >&2
        exit 1
    fi
else
    if [ -n "$(find "$mount_point" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        echo "qdisk: refusing to hide files already present in $mount_point" >&2
        exit 1
    fi
    mount -t ext4 -- "$device" "$mount_point"
fi

chown "$linux_user:$primary_group" -- "$mount_point"
