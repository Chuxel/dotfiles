#!/bin/bash

# Default: Exit on any failure.
set -e

# Setup STDERR.
err() {
    echo "(!) $*" >&2
}

if [ "$(id -u)" -ne 0 ]; then
    err 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Install git, other useful stuff
apt-get update
apt-get install git curl ca-certificates nano zip unzip zsh

# Install Moby
bash -c "$(wget -qO- https://github.com/Chuxel/moby-vscode/raw/main/install-moby.sh)"
usermod -aG docker $(whoami)

# Install nvidia-docker2 - https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html#docker
distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
      && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
      && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-docker2