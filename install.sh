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
    curl -sSL https://github.com/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip -o "$download_to/cascadia.zip"
    unzip -o "$download_to/cascadia.zip" -d "$download_to/cascadia"
    mv -f "$download_to/cascadia/ttf/"*.ttf "$font_folder/"

    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -o "$font_folder/MesloLGS NF Regular.ttf" 
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf -o "$font_folder/MesloLGS NF Bold.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf -o "$font_folder/MesloLGS NF Italic.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf -o "$font_folder/MesloLGS NF Bold Italic.ttf"

    rm -rf "$download_to"
}

if [ "$IS_MACOS" = "true" ]; then
    downloadFonts
    brew install jandedobbeleer/oh-my-posh/oh-my-posh
    cp -f chuxel.omp.json "$HOME/.chuxel.omp.json"
    tee -a "$HOME/.zshrc" > /dev/null \
<< 'EOF'
eval "$(oh-my-posh init zsh --config $HOME/.chuxel.omp.json)"
EOF

else
    # Install curl, tar, git, other dependencies if missing
    packages_needed="\
        curl \
        ca-certificates \
        zip \
        unzip"

    if ! dpkg -s ${packages_needed} > /dev/null 2>&1; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
            sudo apt-get update
        fi
        sudo apt-get -y install ${packages_needed}
    fi

    if ! type git > /dev/null 2>&1; then
        sudo apt-get -y install git
    fi

    # Fonts
    if dpkg -s "fontconfig" > /dev/null 2>&1; then
        downloadFonts
        fc-cache -f -v
    fi

    # Add .local/bin to PATH and if not already present
    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add .local/bin to PATH
export PATH="$HOME/.local/bin:\$PATH"

EOF
    fi

    # Oh My Posh
    curl -s https://ohmyposh.dev/install.sh | bash -s
    cp -f chuxel.omp.json "$HOME/.chuxel.omp.json"
    if ! grep 'oh-my-posh' ~/.bashrc > /dev/null 2>&1; then
    tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add Oh My Posh
eval "$(oh-my-posh init bash --config $HOME/.chuxel.omp.json)"

EOF
    fi

    # Add Tilix
    if ! grep 'TILIX_ID' ~/.bashrc > /dev/null 2>&1; then 
    tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add Tilix
if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
  source /etc/profile.d/vte*.sh
fi

EOF
    fi

    # nvm
    if ! grep 'nvm.sh' ~/.bashrc > /dev/null 2>&1 && ! type nvm  > /dev/null 2>&1; then
    tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

EOF
    fi
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
