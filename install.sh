#!/bin/sh

# https://github.com/idcrook/i-dotfiles
# https://github.com/anishathalye/dotfiles
# http://dotfiles.github.io
# https://github.com/Kraymer/F-dotfiles 

# Wrapper function to only use sudo if not already root
sudoIf()
{
    if [ "$(id -u)" -ne 0 ]; then
        sudo $@
    else
        $@
    fi
}

# Install packages if on Debian / Ubuntu
if type apt-get > /dev/null 2>&1; then
    sudoIf apt-get install stow
    sudoIf apt-get install bsdmainutils
    
    sudoIf apt-get install zsh git curl
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)"
    chsh -s /usr/bin/zsh 

    # https://github.com/powerline/fonts
    sudoIf apt-get install fonts-powerline
fi

stow zsh --adopt
