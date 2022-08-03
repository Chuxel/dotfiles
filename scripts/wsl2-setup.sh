#!/bin/bash

USERNAME="${1:-chuck}"

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
apt-get install -y git curl ca-certificates nano zip unzip zsh
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager-core.exe"

# Install nvm, node, yarn, node-gyp deps
su ${USERNAME} -c '\
    if ! type nvm  > /dev/null 2>&1; then curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash && . "$HOME/.nvm/nvm.sh" && nvm install lts/*; fi \
    && if ! type yarn > /dev/null 2>&1; then npm install -g yarn; fi'
apt-get update
apt-get install -y python3-minimal gcc g++ make

# Install Moby
if ! type docker > /dev/null 2>&1; then
    bash -c "$(wget -qO- https://github.com/Chuxel/moby-vscode/raw/main/install-moby.sh)"
    usermod -aG docker ${USERNAME}
    # Install nvidia-docker2 - https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html#docker
    . /etc/os-release
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/$ID$VERSION_ID/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-docker2
fi


