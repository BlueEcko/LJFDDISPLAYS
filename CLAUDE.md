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

- `install.sh` — One-time setup script. Run as root on fresh Pi OS Lite. Installs packages, creates kiosk user, deploys all files, enables the systemd service. Auto-detects Chromium package name (`chromium` vs `chromium-browser`).
- `kiosk.sh` — Kiosk launcher. Installed as `/home/kiosk/.xinitrc`. Sources the config, disables DPMS, detects screen resolution via xrandr, cleans Chromium crash state, exec's Chromium with `--window-size` to fill the display.
- `kiosk.service` — systemd unit. Runs `startx -- -nocursor` as the kiosk user on tty1. `Restart=always` for crash recovery.
- `kiosk.conf` — URL configuration template. Installed to `/boot/firmware/kiosk.conf`. Two URL slots with an `ACTIVE_URL` selector.
- `10-modesetting.conf` — X11 config. Installed to `/etc/X11/xorg.conf.d/`. Forces modesetting driver on the correct DRM device (Pi 5 has two: V3D for 3D compute, VC4 for display output).

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
- `sudo -u kiosk DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority xrandr` — check display resolution

Quick update after pushing changes (no need to rerun full install):
```
cd ~/LJFDDISPLAYS && git pull && sudo cp kiosk.sh /home/kiosk/.xinitrc && sudo systemctl restart kiosk
```

## Known Gotchas

- Pi OS Lite does not include `git` — install with `sudo apt-get install -y git`
- Chromium package is `chromium` on Bookworm+, `chromium-browser` on older releases. Both install.sh and kiosk.sh auto-detect.
- X display commands (xrandr, xset) must run as the `kiosk` user with `DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority`
- The repo is private — cloning requires a GitHub Personal Access Token or SSH key
- **Pi 5 GPU**: Has two DRM devices — V3D (`/dev/dri/card0`, 3D-only) and VC4 (`/dev/dri/card1`, display). X picks the wrong one without `10-modesetting.conf`. Do NOT install `xserver-xorg-video-fbdev` — it conflicts with modesetting.
- **Pi 5 X permissions**: Requires `xserver-xorg-legacy` package (provides `Xorg.wrap`) so `Xwrapper.config` settings (`needs_root_rights=yes`) are honored. Without it, non-root users get "Cannot open /dev/tty0".

## Do NOT

- Install a desktop environment or window manager
- Use Wayland/cage/labwc (X11 was chosen deliberately for minimal footprint and reliable cursor hiding)
- Add auto-refresh logic (the webpage handles its own refresh)
- Run install.sh from the Windows dev machine — it runs on the Pi
