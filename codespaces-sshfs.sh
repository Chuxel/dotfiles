#!/bin/bash
#
# Usage: codespace-sshfs.sh <container user> <local forwarded SSH port> <codespace folder> <debug mode flag>

set -e
USERNAME=${1:-vscode}
USER_AT_HOST="${USERNAME}@localhost"
PORT="${2:-2222}"
FOLDER="${3:-"/workspaces"}"
DEBUG="${4:-"false"}"

# Make the directory where the remote filesystem will be mounted
DESCRIPTION="GitHub Codespaces ($(openssl rand -hex 2))"
MOUNTPOINT="$HOME/sshfs/$DESCRIPTION"
mkdir -p "$MOUNTPOINT"

# Debug args if specified
if [ "$DEBUG" = "true" ]; then
    SSHFS_DEBUG_ARGS="-odebug,loglevel=error"
else 
    SSHFS_DEBUG_ARGS=""
fi

# Mount the remote filesystem
sshfs $SSHFS_DEBUG_ARGS "$USER_AT_HOST:$FOLDER" "$MOUNTPOINT" -ovolname="$DESCRIPTION" -p $PORT -o workaround=nonodelay -o transform_symlinks -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  -C

# Wait for user input.
echo -e "\nMount: \"$MOUNTPOINT\" \n\nPress \"enter\" to unmount when you are done, or press Ctrl+C to unmount from Finder manually later."
read NOOP

# Unmount and cleanup
umount "$MOUNTPOINT"
rm -rf "$MOUNTPOINT"
