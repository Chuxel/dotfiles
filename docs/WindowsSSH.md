# Initial Setup

https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse?tabs=gui&pivots=windows-server-2025

1. Install SSH server via optional features
2. Start and set things up in an admin PowerShell:
    ```powershell
    Start-Service sshd
    Start-Service ssh-agent
    Set-Service -Name sshd -StartupType 'Automatic'
    Set-Service -Name ssh-agent -StartupType 'Automatic'

    if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue | Select-Object Name, Enabled)) {
        Write-Output "Firewall Rule 'OpenSSH-Server-In-TCP' does not exist, creating it..."
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    } else {
        Write-Output "Firewall rule 'OpenSSH-Server-In-TCP' has been created and exists."
    }
    ```

# Allow per user admin user SSH keys
https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement

1. Open `C:\ProgramData\ssh\sshd_config` in an editor
2. Comment out these two lines:
    ```
    # Match Group administrators
    #       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
    ```
3. You can now add your own public keys to `C:\Users\<username>\.ssh\authorized_keys`
4. Change the privs of this file using `icacls.exe "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`

# Updating the default shell
Updating to PowerShell:

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```

Updating to WSL:
```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Program Files\WSL\wsl.exe" -PropertyType String -Force
```

or back to cmd

```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\cmd.exe" -PropertyType String -Force
```
