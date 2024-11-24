#!/bin/sh
cd "$(dirname $0)"
overwrite="${1:-true}"

if echo "$OSTYPE" | grep -E '^darwin'; then
    IS_MACOS="true"
fi

downloadFonts() {
    if [ -z $TMPDIR ]; then
        TMPDIR=/tmp
    fi

    local download_to="$TMPDIR/dotfiles-fonts"

    if [ "$IS_MACOS" = "true" ]; then
        local font_folder="$HOME/Library/Fonts"
    else
        local font_folder="$HOME/.local/share/fonts" 
    fi

    mkdir -p "$font_folder" "$download_to"
    curl -sSL https://github.com/microsoft/cascadia-code/releases/download/v2105.24/CascadiaCode-2105.24.zip -o "$download_to/cascadia.zip"
    unzip -o "$download_to/cascadia.zip" -d "$download_to/cascadia"
    mv -f "$download_to/cascadia/ttf/"*.ttf "$font_folder/"

    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -o "$font_folder/MesloLGS NF Regular.ttf" 
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf -o "$font_folder/MesloLGS NF Bold.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf -o "$font_folder/MesloLGS NF Italic.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf -o "$font_folder/MesloLGS NF Bold Italic.ttf"

    curl -sSL https://github.com/githubnext/monaspace/releases/download/v1.000/monaspace-v1.000.zip -o "$download_to/monaspace.zip"
    unzip -o "$download_to/monaspace.zip" -d "$download_to/monaspace"
    rm -rf "$HOME"/.local/share/fonts/Monaspace*
    cp "$download_to"/monaspace/fonts/otf/* ~/.local/share/fonts
    cp "$download_to"/monaspace/fonts/variable/* ~/.local/share/fonts

    rm -rf "$download_to"
}

if [ "$IS_MACOS" = "true" ]; then
    downloadFonts
else
    # Install curl, tar, git, other dependencies if missing
    packages_needed="\
        curl \
        ca-certificates \
        zip \
        unzip \
        zsh \
        libfuse2 \
        libssl-dev \
        python3-dev \
        python3-pip \
        python3-setuptools \
        build-essential"

    if ! dpkg -s ${packages_needed} > /dev/null 2>&1; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
            sudo apt-get update
        fi
        sudo apt-get -y install ${packages_needed}
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

fi

# Oh My Zsh!
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi
if [ ! -e "$HOME/.zshrc" ] || [ "${overwrite}" = "true" ]; then
    rm -f  "$HOME/.zshrc"
    ln -s "$(pwd)/.zshrc" $HOME
fi

# powerline 10k
P110K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ ! -d "$P110K_DIR" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P110K_DIR"
fi
if [ ! -e "$HOME/.p10k.zsh" ] || [ "${overwrite}" = "true" ]; then
    rm -f  "$HOME/.p10k.zsh"
    ln -s "$(pwd)/.p10k.zsh" $HOME
fi 

# SSH config file - copy rather than link so machine specific updates can happen
if [ ! -e "$HOME/.ssh/config" ] || [ "${overwrite}" = "true" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    cp -f .ssh/config "$HOME/.ssh/"
    chmod 600 "$HOME/.ssh/config"
fi

# Set git username and email
if [ ! -e "$HOME/.gitconfig" ] || [ "${overwrite}" = "true" ]; then
    git config --global user.email 'chuck_lantz@hotmail.com'
    git config --global user.name 'Chuck Lantz'
fi

# In codespaces, use GitHub public keys as authorized keys to my codespaces (assuming sshd has been set up in them)
if [ "${CODESPACES}" = "true" ]; then
    curl -sSL https://github.com/chuxel.keys -o "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

# Get rid of annoying git message on pull behaviors
git config --global pull.rebase false
