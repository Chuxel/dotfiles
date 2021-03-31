#!/bin/bash
if [ "$(if -u)" != "0" ]; then
    echo "This script must be run as root."
    exit 1
fi

apt-get install -y lubuntu-desktop tigervnc-xorg-extension tigervnc-standalone-server tigervnc-scraping-server tigervnc-common
echo "if ! lsof /usr/bin/Xtigervnc > /dev/null 2>&1; then tigervncserver -rfbport 5900 -localhost > /dev/null 2>&1; fi" >> ~/.bashrc
echo "Restart so settings take effect."