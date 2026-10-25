# Dotfiles

Persönliche Konfigurationsdateien und Einrichtungsskripte für Windows, macOS und Debian-/Ubuntu-basierte Linux-Systeme (einschließlich WSL). Die Skripte sind auf die Umgebung des Repository-Eigentümers zugeschnitten und sollten vor der Ausführung geprüft werden.

## Einrichtung

Repository klonen und im Repository-Verzeichnis den passenden Befehl ausführen:

**Windows (PowerShell):**

```powershell
.\install.ps1 -Overwrite:$false
```

**macOS, Ubuntu/Debian oder WSL (Bash):**

```bash
bash ./install.sh false
```

Beide Skripte installieren unter anderem Schriftarten, Oh My Posh, eine JavaScript-Laufzeitumgebung, GitHub CLI und Copilot CLI. Sie ändern außerdem Shell- und Git-Konfigurationen; einige Schritte benötigen Administratorrechte oder `sudo` und laden Software aus dem Internet herunter.

Die obigen Beispiele erhalten eine bereits vorhandene Git-Benutzeridentität in `~/.gitconfig`. Fehlt diese Datei, tragen die Skripte auch mit deaktiviertem Überschreiben den Namen und die E-Mail-Adresse des Repository-Eigentümers ein. Ohne `-Overwrite:$false` bzw. `false` ist das Überschreiben standardmäßig aktiviert. **Diese Option schützt nicht alle anderen Dateien und Einstellungen:** Vor der Ausführung die Skripte prüfen und die persönlichen Git-Angaben anpassen.

## Inhalt

- `install.ps1` und `install.sh`: Einrichtung für Windows beziehungsweise macOS/Linux/WSL.
- `chuxel.omp.json`, `zsh/` und `.zshrc`: Prompt- und Shell-Konfiguration.
- `devbox/`: Hilfsprogramme für Entwicklungsumgebungen und WSL, jeweils mit eigener Dokumentation.
- `scripts/`: Weitere Skripte für Entwicklungsumgebungen und Server.
- `docs/WindowsSSH.md`: Hinweise zur SSH-Einrichtung unter Windows.
