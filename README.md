# Tally Client Setup

This public repo contains the Windows setup helper for office laptops.

It installs or checks Tailscale, creates the selected Tally RemoteApp shortcut, saves the user's `az-server` credentials in Windows Credential Manager, maps `ExcelFolderD` to `Z:`, and creates a desktop shortcut.

## Easiest way for staff

Download and run:

```text
run-tally-setup.cmd
```

The `.cmd` file always downloads the latest `install.ps1` from this repo before running setup.

## One-command setup

Open PowerShell as Administrator and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nikhilsheoran/tally-client-setup/main/install.ps1 | iex"
```

## Notes

- The script needs administrator permission so it can install Tailscale if missing.
- The user must sign in to Tailscale when prompted.
- The script asks which shortcut to create: `TallyPrime`, `TallyPrime1`, or both.
- No passwords, Tailscale auth keys, restic secrets, or rclone tokens belong in this repo.
