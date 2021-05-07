#!/bin/bash
#
# Usage: devcontainer-ssh.sh [container user] [local forwarded SSH port]

set -e
USERNAME=${1:-vscode}
USER_AT_HOST="${USERNAME}@localhost"
PORT="${2:-2222}"

ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER_AT_HOST"
