#!/bin/bash
#
# Usage: devcontainer-sshfs.sh [container user] [local forwarded SSH port] [dev container folder] [debug mode flag]

set -e
USERNAME=${1:-vscode}
USER_AT_HOST="${USERNAME}@localhost"
PORT="${2:-2222}"
FOLDER="${3:-"/workspaces"}"
DEBUG="${4:-"false"}"

# Make the directory where the remote filesystem will be mounted
DESCRIPTION="Dev Container ($(openssl rand -hex 2))"
MOUNTPOINT="$HOME/sshfs/$DESCRIPTION"
mkdir -p "$MOUNTPOINT"

# Debug args if specified
if [ "$DEBUG" = "true" ]; then
    SSHFS_DEBUG_ARGS="-odebug,loglevel=error"
else 
    SSHFS_DEBUG_ARGS=""
fi

# Mount the remote filesystem
if echo "$OSTYPE" | grep -E '^darwin' > /dev/null 2>&1; then
    sshfs "$USER_AT_HOST:$FOLDER" "$MOUNTPOINT" -p $PORT -ovolname="$DESCRIPTION" -o follow_symlinks -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -C $SSHFS_DEBUG_ARGS
else
    sshfs "$USER_AT_HOST:$FOLDER" "$MOUNTPOINT" -p $PORT -o follow_symlinks -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -C $SSHFS_DEBUG_ARGS
fi

# Wait for user input.
echo -e "\nMount: \"$MOUNTPOINT\" \n\nPress \"enter\" to unmount when you are done, or press Ctrl+C to unmount from Finder manually later."
read NOOP

# Unmount and cleanup
umount "$MOUNTPOINT"
rm -rf "$MOUNTPOINT"
