#!/bin/bash
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root."
    exit 1
fi

RC_SNIPPET="if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi"

apt-get update
apt-get install -y lubuntu-desktop tigervnc-xorg-extension tigervnc-standalone-server tigervnc-scraping-server tigervnc-common
if ! grep "${RC_SNIPPET}" ~/.bashrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> ~/.bashrc
fi
if ! grep "${RC_SNIPPET}" ~/.zshrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> ~/.zshrc
fi
if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi


# Install VS Code Insiders
curl -sSL 'https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64' -o /tmp/code.deb
apt-get -y install /tmp/code.deb
curl -sSL 'https://go.microsoft.com/fwlink/?LinkID=760865' -o /tmp/code-insiders.deb
apt-get -y install /tmp/code-insiders.deb
rm /tmp/code-insiders.deb /tmp/code.deb

# Install Chrome
curl -sSL 'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' -o /tmp/chrome.deb
apt-get -y install /tmp/chrome.deb
rm /tmp/chrome.deb

echo "Restart so settings take effect."