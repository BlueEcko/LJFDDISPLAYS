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
- `usdd-capture-setup.sh` → `/usr/local/sbin/`. Boot-time pipeline bring-up: finds the tc358743 nodes (they renumber per boot); if a live 1080p30 signal is already present it uses it **untouched** (the USDD holds its mode across Pi reboots), otherwise presents the EDID — but it **never** does a `--clear-edid`/long-HPD toggle, which severs this USDD's output. Applies DV timings, wires `csi2 -> /dev/video0` as BGR3 1920x1080. Requires 30 fps (fails safe on 60).
- `usdd-capture-setup.service` — oneshot, `RemainAfterExit`, retries every 15 s until the signal locks (USDD may be absent/over-cap at boot).
- `usdd-switcher.py` → `/usr/local/bin/`. The switcher. Runs as the `kiosk` user in the X session (`DISPLAY=:0`, like kiosk-refresh). Watches a downscaled GRAY8 frame; on alert it starts a GStreamer pipeline whose X video sink (`USDD_SINK`, default `ximagesink`) overlays Chromium full-screen — **no kiosk stop, no reload** — teeing a detection feed alongside; hands back on clear/timeout. Requires the display at the capture's **1080p** (`FORCE_RESOLUTION`) so the sink fills the screen with no scaling. Uses `python3-gi` + `python3-xlib` to **pre-create** a fullscreen override-redirect window and hand its XID to the sink via `GstVideoOverlay` (`set_window_handle` + a `prepare-window-handle` sync handler), so the capture is placed correctly from the first frame — no window-manager-less placement settle. IDLE detection is still a `gst-launch` subprocess; the ALERT pipeline is in-process (gi).
- `usdd-switcher.service` — runs the switcher as `kiosk`, `Requires=usdd-capture-setup.service`, `Wants=kiosk.service`, `RuntimeDirectory=usdd`.
- `kiosk.sh` `FORCE_RESOLUTION` (from kiosk.conf) forces the HDMI mode (e.g. `1920x1080`) so the 4K panels output 1080p to match the capture; the TV upscales.
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
- **USDD capture — EDID re-read / never clear-edid**: This USDD re-reads the EDID **only on its own power-cycle** — a Pi-side HPD toggle won't force it, and a `--clear-edid` (long HPD-low) actually **severs its output** until it is power-cycled. So `usdd-capture-setup.sh` never clears the EDID: it uses a live 1080p30 signal as-is (the USDD holds its mode across Pi reboots) and only `--set-edid` when no good signal exists. Deployment/power-outage recovery = power-cycle the USDD (with the 1080p30 EDID already present, it selects 30).
- **USDD capture — pipeline formats**: `csi2` pads must be set with `colorspace:srgb` (omitting it → EPIPE/`-32` "Failed to start media pipeline"), the video node must be `BGR3` to match `BGR888_1X24` (RGB3 → "Format mismatch"/`-22`), and the `csi2:4 -> rp1-cfe-csi2_ch0` link must be enabled explicitly.
- **USDD capture — this v4l2-ctl build** lacks `--fix-edid-checksums` (the flag aborts the whole command). The shipped `1080P30EDID.txt` already has valid checksums, so the flag isn't used.
- **USDD capture — 1080p30 is mandatory; 60 fps wedges the Pi**: 1080p60 (148.5 MHz) locks under the 165 MHz cap but its bandwidth **hard-hangs the kernel** over the single CSI-2 lane (SSH dies, boot sticks). `usdd-capture-setup` therefore requires a real 30 fps clock (60–80 MHz) and **fails safe** on 60 rather than configuring/streaming it. The shipped `1080P30EDID.txt` has tight range limits (max 40 Hz / 40 kHz / 80 MHz) so the USDD can't pick 60.
- **USDD — the source needs a full POWER-CYCLE to re-read the EDID**: at least one USDD unit ignores the Pi's HPD toggle (`--clear-edid`/`--set-edid`) and only re-reads the EDID (and thus drops to 1080p30) on its own power-up. Bring-up on such a unit: fit board, boot Pi, then power-cycle the USDD, then `systemctl restart usdd-capture-setup usdd-switcher`.
- **USDD switcher — boot recovery**: if a board-equipped Pi ever hangs at boot on `usdd-capture-setup`, mask it without console access — SD card into any computer, append `systemd.mask=usdd-capture-setup.service systemd.mask=usdd-switcher.service` to `cmdline.txt` on the FAT32 boot partition. The service also has `TimeoutStartSec=90`. Detection reference (`/etc/usdd/idle.gray`) is per-device via `usdd-calibrate.sh idle` (reads the switcher's own `/run/usdd` feed, since the switcher owns `/dev/video0`).
- **USDD switcher — display path**: The panels are **4K**, but the kiosk is forced to output **1080p** (`FORCE_RESOLUTION=1920x1080` in kiosk.conf; the TV upscales) so the 1080p capture matches the screen. The alert view then overlays via a GStreamer **X-client sink** (`USDD_SINK`, default `ximagesink`) run as the `kiosk` user against `DISPLAY=:0` — layered over Chromium with no kiosk stop and no reload. Do NOT use `glimagesink` — its GL comes up **black** under this WM-less/modesetting X. Why 1080p and not native 4K: an X sink has no hardware scaler here, so at 4K the 1080p sink only fills a quadrant. Fallback if X sinks won't render at all: the `kmssink`+stop-kiosk build (git history, commit `104e8ca`) works at any resolution but stops the kiosk and reloads the dashboard on hand-back.

## Do NOT

- Install a desktop environment or window manager
- Use Wayland/cage/labwc (X11 was chosen deliberately for minimal footprint and reliable cursor hiding)
- Add auto-refresh logic (the webpage handles its own refresh)
- Run install.sh from the Windows dev machine — it runs on the Pi
