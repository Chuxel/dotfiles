#!/bin/bash

# Install curl, tar, git, other dependencies if missing
PACKAGES_NEEDED="\
    curl \
    ca-certificates \
    unzip \
    git \
    zsh"

if ! dpkg -s ${PACKAGES_NEEDED} > /dev/null 2>&1; then
    if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
        sudo apt-get update
    fi
    sudo apt-get -y install ${PACKAGES_NEEDED}
fi

# Fonts
if ! dpkg -s "fontconfig" > /dev/null 2>&1; then
    mkdir -p $HOME/.local/share/fonts /tmp/cascadia
    curl -sSL https://github.com/microsoft/cascadia-code/releases/download/v2009.22/CascadiaCode-2009.22.zip -o /tmp/cascadia.zip
    unzip /tmp/cascadia.zip -d /tmp/cascadia
    mv /tmp/cascadia/ttf/*.ttf "$HOME/.local/share/fonts/" 
    rm -rf /tmp/cascadia /tmp/cascadia.zip
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -o "$HOME/.local/share/fonts/MesloLGS NF Regular.ttf" 
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf -o "$HOME/.local/share/fonts/MesloLGS NF Bold.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf -o "$HOME/.local/share/fonts/MesloLGS NF Italic.ttf"
    curl -sSL https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf -o "$HOME/.local/share/fonts/MesloLGS NF Bold Italic.ttf"
    fc-cache -f -v
fi

# Oh My Zsh!
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
    sudo chsh -s $(which zsh)
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

cp -f .zshrc $HOME
cp -f .p10k.zsh $HOME
