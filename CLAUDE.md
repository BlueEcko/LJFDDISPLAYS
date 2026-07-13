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
- **Nightly reboot**: systemd timer `kiosk-reboot.timer` triggers `shutdown -r now` at 03:00 daily
- **Hourly refresh**: systemd timer `kiosk-refresh.timer` fires at HH:15 — runs `xdotool key ctrl+shift+r` as the kiosk user to send a hard reload to the focused Chromium window (no Chromium restart, no blank screen)

## File Roles

- `install.sh` — One-time setup script. Run as root on fresh Pi OS Lite. Installs packages, creates kiosk user, deploys all files, enables the systemd service. Auto-detects Chromium package name (`chromium` vs `chromium-browser`).
- `kiosk.sh` — Kiosk launcher. Installed as `/home/kiosk/.xinitrc`. Sources the config, disables DPMS, detects screen resolution via xrandr, cleans Chromium crash state, exec's Chromium with `--window-size` to fill the display.
- `kiosk.service` — systemd unit. Runs `startx -- -nocursor` as the kiosk user on tty1. `Restart=always` for crash recovery.
- `kiosk.conf` — URL configuration template. Installed to `/boot/firmware/kiosk.conf`. Two URL slots with an `ACTIVE_URL` selector.
- `10-modesetting.conf` — X11 config. Installed to `/etc/X11/xorg.conf.d/`. Forces modesetting driver on the correct DRM device (Pi 5 has two: V3D for 3D compute, VC4 for display output).
- `kiosk-reboot.service` / `kiosk-reboot.timer` — Nightly 03:00 reboot. Installed to `/etc/systemd/system/`.
- `kiosk-refresh.service` / `kiosk-refresh.timer` — Hourly hard refresh at HH:15. The service runs as `kiosk` with `DISPLAY=:0` and invokes `xdotool key ctrl+shift+r`.

### USDD Alert Switcher (optional, needs a 52pi TC358743 HDMI-to-CSI2 board)

- `1080P30EDID.txt` — Single-block EDID advertising only 1920x1080p30. Deployed to `/etc/usdd/`. Presented to the USDD (an EDID-driven Broadcom/Pi source) so it outputs 1080p30 @ 74.25 MHz — under the tc358743 driver's 165 MHz pixel-clock cap (its default 173 MHz CVT 1080p60 is rejected as out-of-range, and 1080p60's bandwidth also crashes the single CSI lane).
- `usdd-capture-setup.sh` → `/usr/local/sbin/`. Boot-time pipeline bring-up: finds the tc358743 media/subdev nodes (they renumber per boot), sets the EDID (with a ~20 s HPD-low hold to force a latched USDD to re-read), applies DV timings, wires `csi2 -> /dev/video0` as BGR3 1920x1080.
- `usdd-capture-setup.service` — oneshot, `RemainAfterExit`, retries every 15 s until the signal locks (USDD may be absent/over-cap at boot).
- `usdd-switcher.py` → `/usr/local/bin/`. The switcher. Runs as **root**. Watches a downscaled GRAY8 frame; on alert it **stops kiosk.service** and starts a GStreamer pipeline that paints the capture full-screen via **kmssink** (hardware-scaled 1080p→4K), teeing a detection feed alongside; on clear/timeout it stops kmssink and **restarts kiosk** (dashboard cold-reloads).
- `usdd-switcher.service` — runs the switcher as root, `Requires=usdd-capture-setup.service`, `Wants=kiosk.service`, `RuntimeDirectory=usdd`.
- `usdd.conf` → `/boot/firmware/`. Thresholds, debounce, timeout, reference path, sink. Operator-editable.
- `usdd-calibrate.sh` → `/usr/local/sbin/`. `idle` saves the reference frame; `measure` prints live MAD so thresholds can be tuned against a real test alert.

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
- `systemctl list-timers kiosk-*` — verify next reboot/refresh times
- `sudo systemctl start kiosk-refresh.service` — fire a manual hard refresh now (for testing)

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
- **USDD capture — pixel-clock cap**: The tc358743 driver caps DV timings at 165 MHz. A live USDD defaults to 1920x1080p60 as a **CVT** timing at 173 MHz → `--query-dv-timings` fails `ENOSPC/ERANGE`. Our 1080p30 EDID pulls it to 74.25 MHz. 1080p60 (148.5 MHz) *does* lock but its bandwidth **crashes the box** over the single CSI-2 lane — so 1080p30 is mandatory, not a preference.
- **USDD capture — EDID re-read**: A USDD that has been running only re-reads the EDID on a genuine hot-plug. `--set-edid` alone (short HPD blip) is NOT enough; `usdd-capture-setup.sh` does `--clear-edid`, sleeps ~20 s, then `--set-edid`. This adds ~20-30 s to boot before capture is ready.
- **USDD capture — pipeline formats**: `csi2` pads must be set with `colorspace:srgb` (omitting it → EPIPE/`-32` "Failed to start media pipeline"), the video node must be `BGR3` to match `BGR888_1X24` (RGB3 → "Format mismatch"/`-22`), and the `csi2:4 -> rp1-cfe-csi2_ch0` link must be enabled explicitly.
- **USDD capture — this v4l2-ctl build** lacks `--fix-edid-checksums` (the flag aborts the whole command). The shipped `1080P30EDID.txt` already has valid checksums, so the flag isn't used.
- **USDD switcher — display path**: The alert view uses **kmssink** (DRM) with the kiosk **stopped** for the alert's duration, because the panels run at **4K** and only kmssink hardware-scales the 1080p capture to fill the screen. The X software sinks were tried and rejected: `glimagesink` (GL) renders **black** under this WM-less/modesetting X, and `ximagesink` would software-upscale 1080p→4K every frame (too heavy) and only fills a 1080p window (¼ of the 4K screen). Because kmssink needs the DRM device, the kiosk (X) must yield — hence the stop/start and the dashboard cold-reload on hand-back. The switcher therefore runs as root (not the kiosk user).

## Do NOT

- Install a desktop environment or window manager
- Use Wayland/cage/labwc (X11 was chosen deliberately for minimal footprint and reliable cursor hiding)
- Add auto-refresh logic (the webpage handles its own refresh)
- Run install.sh from the Windows dev machine — it runs on the Pi
