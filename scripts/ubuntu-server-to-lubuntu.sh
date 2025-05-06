#!/bin/bash
if [ "$(id -u)" = "0" ]; then
    echo "Dieses Skript darf nicht als Root ausgeführt werden. Sie werden bei Bedarf nach Ihrem sudo-Passwort gefragt."
    exit 1
fi

RC_SNIPPET="if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi"
TILIX_SNIPPET='if [ $TILIX_ID ] || [ $VTE_VERSION ]; then source /etc/profile.d/vte*.sh; fi'

sudo apt-get update

# Lubuntu und TigerVNC installieren 🍒
sudo apt-get install -y lubuntu-desktop tigervnc-xorg-extension tigervnc-standalone-server tigervnc-scraping-server tigervnc-common
if ! grep "${RC_SNIPPET}" $HOME/.bashrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> $HOME/.bashrc
fi
if ! grep "${RC_SNIPPET}" $HOME/.zshrc > /dev/null 2>&1; then
    echo "${RC_SNIPPET}" >> $HOME/.zshrc
fi
if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi

# Tilix einrichten - In älteren Ubuntu-Versionen befindet sich Tilix in einem PPA. In Debian Strech befindet es sich in den Backports 🍇
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

# VS Code und VS Code Insiders installieren 🍊
curl -sSL 'https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64' -o /tmp/code.deb
sudo apt-get -y install /tmp/code.deb
curl -sSL 'https://go.microsoft.com/fwlink/?LinkID=760865' -o /tmp/code-insiders.deb
sudo apt-get -y install /tmp/code-insiders.deb
rm /tmp/code-insiders.deb /tmp/code.deb

# Chrome installieren 🍎
curl -sSL 'https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb' -o /tmp/chrome.deb
sudo apt-get -y install /tmp/chrome.deb
rm /tmp/chrome.deb

echo "Verbinden Sie sich wie folgt per SSH, um auf den VNC-Port zuzugreifen: ssh -L 5900:localhost:5900 user@ip-or-dns"
