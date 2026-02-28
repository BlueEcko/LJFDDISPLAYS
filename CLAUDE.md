# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Raspberry Pi 5 kiosk display system. Turns a Pi running Pi OS Lite into a full-screen web display with no desktop environment, no window manager, and no cursor.

## Architecture

- **Display server**: Minimal X11 via xinit/startx (not Wayland — chosen for smallest footprint and built-in cursor hiding)
- **Browser**: Chromium in `--kiosk` mode, launched directly from `.xinitrc` (no window manager needed)
- **Cursor**: Hidden by X server `-nocursor` flag (no extra packages)
- **Screen power**: DPMS disabled via `xset` in kiosk.sh; console blanking off via kernel param `consoleblank=0`
- **Auto-recovery**: systemd `Restart=always` — Chromium exits → X exits → startx exits → systemd restarts
- **Config**: `/boot/firmware/kiosk.conf` (shell-sourceable, on FAT32 boot partition, editable from any OS)

## File Roles

- `install.sh` — One-time setup script. Run as root on fresh Pi OS Lite. Installs 6 packages, creates kiosk user, deploys all files, enables the systemd service.
- `kiosk.sh` — Kiosk launcher. Installed as `/home/kiosk/.xinitrc`. Sources the config, disables DPMS, cleans Chromium crash state, exec's Chromium.
- `kiosk.service` — systemd unit. Runs `startx -- -nocursor` as the kiosk user on tty1. `Restart=always` for crash recovery.
- `kiosk.conf` — URL configuration template. Installed to `/boot/firmware/kiosk.conf`. Two URL slots with an `ACTIVE_URL` selector.

## Key Patterns

- kiosk.sh uses `exec` to replace the shell with Chromium. When Chromium exits, the X session ends, startx exits, and systemd restarts the service.
- Config is loaded via `source /boot/firmware/kiosk.conf` (bash variable assignment syntax).
- All files in this repo are source templates; `install.sh` copies them to their runtime locations on the Pi.

## Testing and Debugging

This runs on a Raspberry Pi, not locally. To test:
1. Flash Pi OS Lite to an SD card, boot the Pi
2. SSH in, clone the repo, run `sudo bash install.sh`
3. Edit `/boot/firmware/kiosk.conf` with real URLs, then `sudo reboot`

Useful commands (on the Pi via SSH):
- `journalctl -u kiosk.service -f` — live service logs
- `cat /var/log/kiosk.log` — kiosk script logs
- `sudo systemctl restart kiosk` — restart after config change
- `sudo systemctl status kiosk` — check service status

## Do NOT

- Install a desktop environment or window manager
- Use Wayland/cage/labwc (X11 was chosen deliberately for minimal footprint and reliable cursor hiding)
- Add auto-refresh logic (the webpage handles its own refresh)
- Run install.sh from the Windows dev machine — it runs on the Pi
