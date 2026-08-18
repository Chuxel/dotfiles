#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
overwrite="${1:-true}"

rc_file="$HOME/.bashrc"
IS_MACOS="false"
IS_WSL="false"

if [ "$(uname -s)" = "Darwin" ]; then
    IS_MACOS="true"
    rc_file="$HOME/.zshrc"
elif [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL="true"
fi

configureWslInterop() {
    if [ "$IS_WSL" != "true" ]; then
        return
    fi

    local wsl_config
    wsl_config="$(mktemp "${TMPDIR:-/tmp}/wsl.conf.XXXXXX")"

    if [ -f /etc/wsl.conf ]; then
        cat /etc/wsl.conf
    fi | awk '
        function is_section(line) {
            return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/
        }

        function is_interop(line, normalized) {
            normalized = tolower(line)
            gsub(/[[:space:]]/, "", normalized)
            return normalized == "[interop]"
        }

        function is_append_windows_path(line, normalized) {
            normalized = tolower(line)
            return normalized ~ /^[[:space:]]*appendwindowspath[[:space:]]*=/
        }

        is_section($0) {
            if (in_interop && !has_setting) {
                print "appendWindowsPath = false"
            }

            in_interop = is_interop($0)
            if (in_interop) {
                found_interop = 1
                has_setting = 0
            }
        }

        in_interop && is_append_windows_path($0) {
            print "appendWindowsPath = false"
            has_setting = 1
            next
        }

        { print }

        END {
            if (in_interop && !has_setting) {
                print "appendWindowsPath = false"
            } else if (!found_interop) {
                if (NR > 0) {
                    print ""
                }
                print "[interop]"
                print "appendWindowsPath = false"
            }
        }
    ' > "$wsl_config"

    sudo tee /etc/wsl.conf < "$wsl_config" > /dev/null
    rm -f "$wsl_config"
}

downloadFonts() {
    local download_to="${TMPDIR:-/tmp}/dotfiles-fonts"

    if [ "$IS_MACOS" = "true" ]; then
        local font_folder="$HOME/Library/Fonts"
    else
        local font_folder="$HOME/.local/share/fonts" 
    fi

    mkdir -p "$font_folder" "$download_to"
    curl -fL --progress-bar https://github.com/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip -o "$download_to/cascadia.zip"
    rm -rf "$download_to/cascadia"
    unzip -o "$download_to/cascadia.zip" -d "$download_to/cascadia"
    mv -f "$download_to/cascadia/ttf/"*.ttf "$font_folder/"

    curl -fL --progress-bar https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf -o "$font_folder/MesloLGS NF Regular.ttf"
    curl -fL --progress-bar https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf -o "$font_folder/MesloLGS NF Bold.ttf"
    curl -fL --progress-bar https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf -o "$font_folder/MesloLGS NF Italic.ttf"
    curl -fL --progress-bar https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf -o "$font_folder/MesloLGS NF Bold Italic.ttf"

    rm -rf "$download_to"
}

installBleSh() {
    local ble_path="$HOME/.local/share/blesh/ble.sh"

    if [ ! -f "$ble_path" ]; then
        local download_to
        download_to="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-blesh.XXXXXX")"
        curl -fL --progress-bar https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
            -o "$download_to/ble-nightly.tar.xz"
        tar -xJf "$download_to/ble-nightly.tar.xz" -C "$download_to"
        bash "$download_to/ble-nightly/ble.sh" --install "$HOME/.local/share"
        rm -rf "$download_to"
    fi

    if ! grep -q 'share/blesh/ble.sh' "$HOME/.bashrc" > /dev/null 2>&1; then
        if grep -q 'oh-my-posh init bash' "$HOME/.bashrc" > /dev/null 2>&1; then
            sed -i '\|oh-my-posh init bash|i [ -r "$HOME/.local/share/blesh/ble.sh" ] && source -- "$HOME/.local/share/blesh/ble.sh"' "$HOME/.bashrc"
        else
            printf '\n%s\n' '[ -r "$HOME/.local/share/blesh/ble.sh" ] && source -- "$HOME/.local/share/blesh/ble.sh"' >> "$HOME/.bashrc"
        fi
    fi

    if [ -d "$HOME/.cache/oh-my-posh" ]; then
        find "$HOME/.cache/oh-my-posh" -maxdepth 1 -type f -name 'init.*.sh' -delete
    fi
}

installXcodeCommandLineTools() {
    # Homebrew, git, and compiled dependencies all need the CLT, so do this first
    if xcode-select -p > /dev/null 2>&1; then
        return
    fi

    echo "Xcode Command Line Tools not found. Installing..."

    # This placeholder makes the tools show up as a softwareupdate item
    local progress_file="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    touch "$progress_file"

    local clt_package
    clt_package="$(softwareupdate -l 2>/dev/null \
        | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^ *\*/ {print $2}' \
        | sed -e 's/^ *Label: *//' -e 's/^ *//' \
        | tail -n 1 || true)"

    if [ -n "$clt_package" ]; then
        softwareupdate -i "$clt_package" --verbose
    else
        # Fall back to the GUI installer and wait for the user to finish it
        xcode-select --install > /dev/null 2>&1
        echo "Complete the Command Line Tools installer dialog to continue..."
        while ! xcode-select -p > /dev/null 2>&1; do
            sleep 10
        done
    fi

    rm -f "$progress_file"

    if ! xcode-select -p > /dev/null 2>&1; then
        echo "(!) Xcode Command Line Tools install failed. Run 'xcode-select --install' manually, then re-run this script." >&2
        exit 1
    fi
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
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fL --progress-bar https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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
        curl -fL --progress-bar https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash
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
        curl -fL --progress-bar https://bun.sh/install | bash
    fi

    if ! grep 'BUN_INSTALL' "$rc_file" > /dev/null 2>&1; then
        if [ "$IS_MACOS" = "true" ]; then
            tee -a "$rc_file" > /dev/null \
<< 'EOF'

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

EOF
        else
            tee -a "$rc_file" > /dev/null \
<< 'EOF'

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

EOF
        fi
    fi

    if [ "$IS_MACOS" != "true" ]; then
        sed -i \
            -e '/^# bun completions$/d' \
            -e '\|^\[ -s "\$HOME/.bun/_bun" \] && source "\$HOME/.bun/_bun"$|d' \
            "$rc_file"
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
        curl -fL --progress-bar https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
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

    curl -fL --progress-bar https://gh.io/copilot-install | bash
}

installOhMyPosh() {
    if [ "$IS_MACOS" = "true" ]; then
        if ! type oh-my-posh > /dev/null 2>&1; then
            brew install jandedobbeleer/oh-my-posh/oh-my-posh
        fi
    else
        if [ ! -x "$HOME/.local/bin/oh-my-posh" ]; then
            curl -fL --progress-bar https://ohmyposh.dev/install.sh \
                | bash -s -- -d "$HOME/.local/bin"
        fi
    fi

    if { [ "$IS_MACOS" = "true" ] && ! type oh-my-posh > /dev/null 2>&1; } \
        || { [ "$IS_MACOS" != "true" ] && [ ! -x "$HOME/.local/bin/oh-my-posh" ]; }; then
        echo "(!) Oh My Posh installation could not be verified." >&2
        exit 1
    fi
}

canUseSecretService() {
    # GCM's secretservice store needs libsecret plus a D-Bus session with a
    # Secret Service provider (gnome-keyring, kwallet, keepassxc, ...) running
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        return 1
    fi

    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        return 1
    fi

    if ! (ldconfig -p 2>/dev/null | grep -q 'libsecret-1\.so\.0'); then
        return 1
    fi

    # Confirm something is actually serving org.freedesktop.secrets on the bus
    if type gdbus > /dev/null 2>&1; then
        gdbus call --session \
            --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner org.freedesktop.secrets 2>/dev/null \
            | grep -q 'true'
        return $?
    fi

    if type dbus-send > /dev/null 2>&1; then
        dbus-send --session --print-reply --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
            string:org.freedesktop.secrets 2>/dev/null \
            | grep -q 'boolean true'
        return $?
    fi

    # No way to probe the bus, so fall back to something that always works
    return 1
}

installGitCredentialManager() {
    # Codespaces already wires up credentials via the GITHUB_TOKEN / gh auth
    if [ "${CODESPACES:-}" = "true" ]; then
        return
    fi

    # In WSL, reuse the GCM installed on the Windows host so credentials are shared
    if [ "$IS_WSL" = "true" ]; then
        local windows_gcm
        for candidate in \
            "/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager.exe" \
            "/mnt/c/Program Files (x86)/Git Credential Manager/git-credential-manager.exe" \
            "/mnt/c/Program Files/Git Credential Manager/git-credential-manager.exe" \
            "/mnt/c/Program Files/Git/mingw64/libexec/git-core/git-credential-manager.exe" \
            "/mnt/c/Program Files/Git/mingw64/bin/git-credential-manager-core.exe"
        do
            if [ -x "$candidate" ]; then
                windows_gcm="$candidate"
                break
            fi
        done

        if [ -z "$windows_gcm" ]; then
            echo "(!) Could not find Git Credential Manager on the Windows host. Install Git for Windows or GCM, then re-run." >&2
            return
        fi

        # git needs the spaces in the path escaped
        git config --global credential.helper "$(echo "$windows_gcm" | sed 's/ /\\ /g')"

        # Let the Windows host own the credential store; WSL just calls into it
        git config --global --unset credential.credentialStore > /dev/null 2>&1 || true
        return
    fi

    if ! type git-credential-manager > /dev/null 2>&1; then
        if [ "$IS_MACOS" = "true" ]; then
            brew install --cask git-credential-manager

            # The cask's pkg drops the binary here, which may not be on PATH yet
            for gcm_path in /usr/local/share/gcm-core /usr/local/bin /opt/homebrew/bin; do
                if [ -x "$gcm_path/git-credential-manager" ]; then
                    PATH="$gcm_path:$PATH"
                    export PATH
                    break
                fi
            done
        else
            local gcm_version="2.9.1"
            local gcm_arch="x64"
            if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
                gcm_arch="arm64"
            fi

            local gcm_deb="/tmp/gcm-linux-${gcm_arch}-${gcm_version}.deb"
            curl -fL --progress-bar "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${gcm_version}/gcm-linux-${gcm_arch}-${gcm_version}.deb" -o "$gcm_deb"
            sudo dpkg -i "$gcm_deb" || sudo apt-get -y -f install
            rm -f "$gcm_deb"
        fi
    fi

    if ! type git-credential-manager > /dev/null 2>&1; then
        echo "(!) Git Credential Manager install could not be verified - skipping credential configuration." >&2
        return
    fi

    git-credential-manager configure

    if [ "$IS_MACOS" = "true" ]; then
        git config --global credential.credentialStore keychain
    elif canUseSecretService; then
        git config --global credential.credentialStore secretservice
    else
        # No usable keyring (headless, SSH, container), so persist to disk instead
        local plaintext_store="$HOME/.gcm/store"
        mkdir -p "$plaintext_store"
        chmod 700 "$HOME/.gcm" "$plaintext_store"

        git config --global credential.credentialStore plaintext
        git config --global credential.plaintextStorePath "$plaintext_store"

        echo "(!) No keyring available - GCM credentials will be stored unencrypted in $plaintext_store" >&2
    fi
}

if [ "$IS_MACOS" = "true" ]; then
    installXcodeCommandLineTools
    downloadFonts
    installHomebrew
    installOhMyPosh
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
    configureWslInterop

    # Install curl, tar, git, other dependencies if missing
    packages_needed=(
        curl
        ca-certificates
        zip
        unzip
        xz-utils
    )
    missing_packages=()
    for package in "${packages_needed[@]}"; do
        if ! dpkg -s "$package" > /dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls /var/lib/apt/lists/ | wc -l)" = "0" ]; then
            sudo apt-get update
        fi
        sudo apt-get -y install "${missing_packages[@]}"
    fi

    if ! type git > /dev/null 2>&1; then
        sudo apt-get -y install git
    fi

    for command_name in curl tar unzip; do
        if ! command -v "$command_name" > /dev/null 2>&1; then
            echo "(!) Required command '$command_name' is unavailable after dependency installation." >&2
            exit 1
        fi
    done

    # Fonts
    if dpkg -s "fontconfig" > /dev/null 2>&1; then
        downloadFonts
        fc-cache -f -v
    fi

    # Persist .local/bin even when it is already present in this process's PATH
    if ! grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" > /dev/null 2>&1; then
        if grep -q 'oh-my-posh init bash' "$HOME/.bashrc" > /dev/null 2>&1; then
            sed -i '\|oh-my-posh init bash|i # Add .local/bin to PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' "$HOME/.bashrc"
        else
            tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add .local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"

EOF
        fi
    fi
    export PATH="$HOME/.local/bin:$PATH"

    installOhMyPosh
    installBleSh

    cp -f chuxel.omp.json "$HOME/.chuxel.omp.json"
    sed -i 's|eval "$(oh-my-posh init bash --config \$HOME/.chuxel.omp.json)"|eval "$("$HOME/.local/bin/oh-my-posh" init bash --config "$HOME/.chuxel.omp.json")"|' "$HOME/.bashrc"
    if ! grep 'oh-my-posh' ~/.bashrc > /dev/null 2>&1; then
    tee -a "$HOME/.bashrc" > /dev/null \
<< 'EOF'

# Add Oh My Posh
eval "$("$HOME/.local/bin/oh-my-posh" init bash --config "$HOME/.chuxel.omp.json")"

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
installGitCredentialManager

# Set git username and email
if [ ! -e "$HOME/.gitconfig" ] || [ "${overwrite}" = "true" ]; then
    git config --global user.email 'chuck_lantz@hotmail.com'
    git config --global user.name 'Chuck Lantz'
fi

# Get rid of annoying git message on pull behaviors
git config --global pull.rebase false

# In codespaces, use GitHub public keys as authorized keys to my codespaces (assuming sshd has been set up in them)
if [ "${CODESPACES:-}" = "true" ]; then
    mkdir -p "$HOME/.ssh"
    curl -fL --progress-bar https://github.com/chuxel.keys -o "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi
