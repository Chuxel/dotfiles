#!/bin/sh
cd "$(dirname $0)"
overwrite="${1:-true}"

rc_file="$HOME/.bashrc"
if echo "$OSTYPE" | grep -E '^darwin'; then
    IS_MACOS="true"
    rc_file="$HOME/.zshrc"
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

installHomebrew() {
    if ! type brew > /dev/null 2>&1; then
        # Pick up an existing install that just isn't on the PATH yet
        for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [ -x "$brew_path" ]; then
                eval "$($brew_path shellenv)"
                break
            fi
        done
    fi

    if ! type brew > /dev/null 2>&1; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [ -x "$brew_path" ]; then
                eval "$($brew_path shellenv)"
                break
            fi
        done
    fi

    brew_prefix="$(brew --prefix)"
    if ! grep -q 'brew shellenv' "$HOME/.zshrc" > /dev/null 2>&1; then
        tee -a "$HOME/.zshrc" > /dev/null \
<< EOF

# Add Homebrew
eval "\$(${brew_prefix}/bin/brew shellenv)"

EOF
    fi
}

installNvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    if [ ! -s "$NVM_DIR/nvm.sh" ] && ! type nvm > /dev/null 2>&1; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash
    fi

    if ! grep 'nvm.sh' "$rc_file" > /dev/null 2>&1; then
    tee -a "$rc_file" > /dev/null \
<< 'EOF'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

EOF
    fi
}

installBun() {
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"

    if [ ! -x "$BUN_INSTALL/bin/bun" ] && ! type bun > /dev/null 2>&1; then
        curl -fsSL https://bun.sh/install | bash
    fi

    if ! grep 'BUN_INSTALL' "$rc_file" > /dev/null 2>&1; then
    tee -a "$rc_file" > /dev/null \
<< 'EOF'

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

EOF
    fi
}

installGhCli() {
    if type gh > /dev/null 2>&1; then
        return
    fi

    if [ "$IS_MACOS" = "true" ]; then
        brew install gh
    else
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update
        sudo apt-get -y install gh
    fi
}

installCopilotCli() {
    if type copilot > /dev/null 2>&1; then
        return
    fi

    curl -fsSL https://gh.io/copilot-install | bash
}

if [ "$IS_MACOS" = "true" ]; then
    downloadFonts
    installHomebrew
    brew install jandedobbeleer/oh-my-posh/oh-my-posh
    cp -f chuxel.omp.json "$HOME/.chuxel.omp.json"
    tee -a "$HOME/.zshrc" > /dev/null \
<< 'EOF'
eval "$(oh-my-posh init zsh --config $HOME/.chuxel.omp.json)"
EOF

    # Visual Studio Code
    if ! grep 'Visual Studio Code' "$HOME/.zshrc" > /dev/null 2>&1; then
    tee -a "$HOME/.zshrc" > /dev/null \
<< 'EOF'

# Add Visual Studio Code (code)
if [[ "$OSTYPE" =~ "darwin"* ]]; then
    export PATH="/Applications/Visual Studio Code.app/Contents/Resources/app/bin:${PATH}"
    alias code-insiders='/Applications/Visual\ Studio\ Code\ -\ Insiders.app/Contents/Resources/app/bin/code'
fi

EOF
    fi

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
    if ! echo "$PATH" | grep -q "\$HOME/.local/bin"; then
        tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add .local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"

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

fi

# Adapt to ghostley
if ! grep 'xterm-ghostty' "$rc_file" > /dev/null 2>&1; then 
    tee -a "$rc_file" > /dev/null \
<< 'EOF'

# Adapt to Ghostly
if [ "$TERM" = "xterm-ghostty" ]; then
  export TERM=xterm-256color
fi

EOF
fi

installNvm
installBun
installGhCli
installCopilotCli

# Set git username and email
if [ ! -e "$HOME/.gitconfig" ] || [ "${overwrite}" = "true" ]; then
    git config --global user.email 'chuck_lantz@hotmail.com'
    git config --global user.name 'Chuck Lantz'
fi

# Get rid of annoying git message on pull behaviors
git config --global pull.rebase false

# In codespaces, use GitHub public keys as authorized keys to my codespaces (assuming sshd has been set up in them)
if [ "${CODESPACES}" = "true" ]; then
    mkdir -p /home/$HOME/.ssh
    curl -sSL https://github.com/chuxel.keys -o "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

