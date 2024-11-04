#!/bin/bash

USERNAME="${1:-${USER:-chuck}}"

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
if [ ! -e "/home/${USERNAME}/.nvm" ]; then
    su ${USERNAME} -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash'
fi
su ${USERNAME} -c '. "$HOME/.nvm/nvm.sh" && if ! type node > /dev/null 2>&1; then nvm install --lts; fi' 
su ${USERNAME} -c '. "$HOME/.nvm/nvm.sh" && if ! type yarn > /dev/null 2>&1; then npm install -g yarn; fi'
apt-get update
apt-get install -y python3-minimal gcc g++ make

# Install Moby
if ! type docker > /dev/null 2>&1; then
    bash -c "$(wget -qO- https://github.com/Chuxel/moby-setup/raw/main/install-moby.sh)"
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

# Setup kubectl
if ! type kubectl > /dev/null 2>&1; then
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubectl
fi

# Install kind
if ! type kind > /dev/null 2>&1; then
    curl -sSLo ./kind https://kind.sigs.k8s.io/dl/v0.14.0/kind-linux-$(dpkg --print-architecture)
    chmod +x ./kind
    mv ./kind /usr/local/bin/kind
fi

# Install xubuntu-specific packages
if lsb_release -is | grep -E '^Xubuntu'; then
    apt-get install -y xubuntu-desktop
fi
