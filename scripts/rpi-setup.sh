#/usr/bin/env bash
sudo apt-get -y install libpam-yubico gnome-keyring libsecret-1-0 tilix

# Update for Ubuntu 24.04
sudo apt-get update
sudo apt-get -y install software-properties-common

# Ensure necessary dependencies for Ubuntu 24.04
sudo apt-get -y install curl ca-certificates zip unzip zsh

# Remove deprecated or unnecessary packages
sudo apt-get -y remove some-deprecated-package
