# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Add Visual Studio Code (code)
if [[ "$OSTYPE" =~ "darwin"* ]]; then
  export PATH="/Applications/Visual Studio Code.app/Contents/Resources/app/bin:${PATH}"
  alias code-insiders='/Applications/Visual\ Studio\ Code\ -\ Insiders.app/Contents/Resources/app/bin/code'
fi

# nvm
if ! type nvm  > /dev/null 2>&1; then
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
fi

eval "$(oh-my-posh init zsh --config $HOME/.chuxel.omp.json)"

# bun completions
[ -s "/Users/clantz/.bun/_bun" ] && source "/Users/clantz/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
