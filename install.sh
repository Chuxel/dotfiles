#!/bin/bash

downloadFonts() {
    if [ -z $TMPDIR ]; then
        TMPDIR=/tmp
    fi

    local DOWNLOAD_TO="$TMPDIR/dotfiles-fonts"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        local FONT_FOLDER="$HOME/Library/Fonts"
    else
        local FONT_FOLDER="$HOME/.local/share/fonts" 
    fi

    mkdir -p "$FONT_FOLDER" "$DOWNLOAD_TO"
    curl -sSL https://github.com/microsoft/cascadia-code/releases/download/v2009.22/CascadiaCode-2009.22.zip -o "$DOWNLOAD_TO/cascadia.zip"
    unzip -o "$DOWNLOAD_TO/cascadia.zip" -d "$DOWNLOAD_TO/cascadia"
    mv -f "$DOWNLOAD_TO/cascadia/ttf/"*.ttf "$FONT_FOLDER/"
    rm -rf "$DOWNLOAD_TO"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -o "$FONT_FOLDER/MesloLGS NF Regular.ttf" 
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf -o "$FONT_FOLDER/MesloLGS NF Bold.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf -o "$FONT_FOLDER/MesloLGS NF Italic.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf -o "$FONT_FOLDER/MesloLGS NF Bold Italic.ttf"
}

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Install curl, tar, git, other dependencies if missing
    PACKAGES_NEEDED="\
        curl \
        ca-certificates \
        zip \
        unzip \
        zsh"

    if ! dpkg -s ${PACKAGES_NEEDED} > /dev/null 2>&1; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
            sudo apt-get update
        fi
        sudo apt-get -y install ${PACKAGES_NEEDED}
    fi

    if ! type git > /dev/null 2>&1; then
        sudo apt-get -y git
    fi

    # Fonts
    if dpkg -s "fontconfig" > /dev/null 2>&1; then
        downloadFonts
        fc-cache -f -v
    fi

    # Add Tilix
    if ! grep 'TILIX_ID' ~/.bashrc > /dev/null 2>&1; then 
    tee -a "$HOME/.bashrc" > /dev/null \
<< EOF

# Add Tilix
if [ \$TILIX_ID ] || [ \$VTE_VERSION ]; then
  source /etc/profile.d/vte*.sh
fi
EOF
    fi

elif [[ "$OSTYPE" == "darwin"* ]]; then
    downloadFonts
fi

# Oh My Zsh!
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

if [ ! -f "$HOME/.p10k.zsh" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
fi 

cp -f .zshrc $HOME
cp -f .p10k.zsh $HOME
