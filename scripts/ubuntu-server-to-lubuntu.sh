#!/bin/bash
if [ "$(id -u)" = "0" ]; then
    echo "This script must not be run as root. You will be prompted for your sudo password as needed."
    exit 1
fi

RC_SNIPPET="if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi"
TILIX_SNIPPET='if [ $TILIX_ID ] || [ $VTE_VERSION ]; then source /etc/profile.d/vte*.sh; fi'

sudo apt-get update

# Install Lubuntu and TigerVNC
sudo apt-get install -y lubuntu-desktop tigervnc-xorg-extension tigervnc-standalone-server tigervnc-scraping-server tigervnc-common
if ! grep "${RC_SNIPPET}" $HOME/.bashrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> $HOME/.bashrc
fi
if ! grep "${RC_SNIPPET}" $HOME/.zshrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> $HOME/.zshrc
fi
if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi

# Setup Tilix - On older Ubuntu, Tilix is in a PPA. On Debian Strech, its in backports
if [[ -z $(apt-cache --names-only search ^tilix$) ]]; then
    sudo apt-get install -y --no-install-recommends lsb-release
    if [ "$(lsb_release -is)" = "Ubuntu" ]; then
        sudo apt-get install -y --no-install-recommends apt-transport-https software-properties-common
        sudo add-apt-repository -y ppa:webupd8team/terminix
    else
        echo "deb http://deb.debian.org/debian $(lsb_release -cs)-backports main" | sudo tee /etc/apt/sources.list.d/$(lsb_release -cs)-backports.list > /dev/null
    fi
    sudo apt-get update
fi
sudo apt-get install -y tilix
if ! grep 'TILIX_ID' ~/.bashrc > /dev/null 2>&1; then
    echo "${TILIX_SNIPPET}" >> ~/.bashrc
fi
if ! grep 'TILIX_ID' ~/.zshrc > /dev/null 2>&1; then
    echo "${TILIX_SNIPPET}" >> ~/.zshrc
fi

# Install VS Code and VS Code Insiders
curl -sSL 'https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64' -o /tmp/code.deb
sudo apt-get -y install /tmp/code.deb
curl -sSL 'https://go.microsoft.com/fwlink/?LinkID=760865' -o /tmp/code-insiders.deb
sudo apt-get -y install /tmp/code-insiders.deb
rm /tmp/code-insiders.deb /tmp/code.deb

# Install Chrome
curl -sSL 'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' -o /tmp/chrome.deb
sudo apt-get -y install /tmp/chrome.deb
rm /tmp/chrome.deb

echo "Restart so settings take effect."
