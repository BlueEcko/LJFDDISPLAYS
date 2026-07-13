# LJFD Kiosk Display System

Turns a Raspberry Pi 5 running Pi OS Lite into a full-screen web kiosk display.
No desktop environment, no window decorations, no cursor — just a webpage.

## What You Need

- Raspberry Pi 5 (also works with Pi 4)
- MicroSD card (8GB+ recommended)
- HDMI display
- Network connection (Ethernet or Wi-Fi configured via Raspberry Pi Imager)
- Raspberry Pi OS Lite (64-bit, Bookworm or later)

## Quick Start

### 1. Flash Pi OS Lite

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash
**Raspberry Pi OS Lite (64-bit)** to your SD card.

In Imager settings (gear icon), configure:
- **Hostname**: your choice (e.g., `ljfd-display-1`)
- **Enable SSH**: Yes, with password or public key
- **Set username/password**: Create an admin user (e.g., `pi`)
- **Configure Wi-Fi**: If not using Ethernet

### 2. Boot and Connect

Insert the SD card, connect HDMI and power. Once booted, SSH in:

```bash
ssh pi@ljfd-display-1.local
```

### 3. Install the Kiosk

```bash
sudo apt-get install -y git
git clone https://github.com/BlueEcko/LJFDDISPLAYS.git
cd LJFDDISPLAYS
sudo bash install.sh
```

Note: Git is not included in Pi OS Lite by default and must be installed first.
The repo is private — Git will prompt for GitHub credentials (use a [Personal Access Token](https://github.com/settings/tokens) as the password).

### 4. Configure the URL

Edit the config file:

```bash
sudo nano /boot/firmware/kiosk.conf
```

Set your URLs and choose which one is active:

```ini
URL_1="https://your-display-url.com/screen1"
URL_2="https://your-display-url.com/screen2"
ACTIVE_URL="URL_1"
```

### 5. Reboot

```bash
sudo reboot
```

The Pi will boot directly into a full-screen display of your configured webpage.

## Architecture

```
Boot → systemd starts kiosk.service
     → startx (as 'kiosk' user, no cursor)
     → .xinitrc (kiosk.sh)
     → disable DPMS/screen blanking
     → detect screen resolution via xrandr
     → clean Chromium crash flags
     → exec chromium --kiosk --window-size=WxH <URL>

If Chromium crashes → X session ends → systemd restarts (5s delay)
```

## USDD Alert Switcher (optional)

For sites where a **USDD station-alerting device** must take over the TV during a
call, fit a **52pi TC358743 HDMI-to-CSI2 board** on the Pi's CAM/DISP1 connector
and feed the USDD's HDMI into it. The Pi then acts as a software HDMI switcher:
it shows the dashboard normally, and overlays the live USDD screen full-screen
when an alert appears, handing back when it clears. No TV CEC and no USDD
passthrough required — the TV only ever sees the Pi.

`install.sh` deploys this automatically (it adds `dtoverlay=tc358743,cam1` and
enables `usdd-capture-setup` + `usdd-switcher`). It's inert on Pis with no board
fitted. After installing **with a live USDD wired in**, calibrate detection:

```bash
# 1. With the USDD showing its normal IDLE screen:
sudo usdd-calibrate.sh idle

# 2. Watch the difference reading while a test alert is fired:
sudo usdd-calibrate.sh measure
```

Note the idle reading and the alert reading, then edit `/boot/firmware/usdd.conf`:
set `USDD_ON_THRESHOLD` a little **below** the alert number and
`USDD_OFF_THRESHOLD` a little **above** the idle number, and restart:

```bash
sudo systemctl restart usdd-switcher
```

Bench test the takeover without a real alert: `sudo touch /run/usdd/force-alert`
(remove the file to hand back). Logs: `journalctl -u usdd-switcher -f` and
`journalctl -u usdd-capture-setup`.

**Requirement:** the USDD must run at **1080p30** — the shipped EDID enforces this.
1080p60 exceeds the capture chip's limits and is unstable over the single CSI lane.

## Daily Operations

| Task | Command |
|------|---------|
| Change URL | Edit `/boot/firmware/kiosk.conf`, then `sudo systemctl restart kiosk` |
| View logs | `journalctl -u kiosk.service -f` |
| Kiosk script log | `cat /var/log/kiosk.log` |
| Restart display | `sudo systemctl restart kiosk` |
| Stop display | `sudo systemctl stop kiosk` |
| Check status | `sudo systemctl status kiosk` |
| Update kiosk scripts | `cd ~/LJFDDISPLAYS && git pull && sudo cp kiosk.sh /home/kiosk/.xinitrc && sudo systemctl restart kiosk` |
| SSH in | `ssh pi@<hostname>.local` |

## Changing the URL Without SSH

1. Power off the Pi
2. Remove the SD card
3. Insert it into any computer
4. Edit `kiosk.conf` on the `bootfs` partition
5. Reinsert the SD card and power on

The boot partition is FAT32, readable by Windows, Mac, and Linux.

## Installed Packages

Only 6 packages are installed (with `--no-install-recommends`):

| Package | Purpose |
|---------|---------|
| `xserver-xorg-core` | Minimal X11 display server |
| `xserver-xorg-video-fbdev` | Framebuffer video driver |
| `xserver-xorg-input-libinput` | Input driver (required for X to start) |
| `xinit` | Provides `startx` command |
| `x11-xserver-utils` | Provides `xset` for DPMS control |
| `chromium` or `chromium-browser` | Web browser (name varies by OS version, auto-detected) |

No desktop environment. No window manager. No cursor utility.

## Troubleshooting

**Black screen, no browser:**
```bash
journalctl -u kiosk.service -n 50
cat /var/log/kiosk.log
```

**"Chromium didn't shut down correctly" bar:**
The kiosk script handles this automatically. If it persists:
```bash
rm -rf /home/kiosk/.config/chromium
sudo systemctl restart kiosk
```

**Screen goes blank after a while:**
Check that DPMS is disabled (must run as kiosk user):
```bash
sudo -u kiosk DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority xset q | grep -i dpms
```
Check kernel param:
```bash
cat /proc/cmdline | grep consoleblank
```

**Display not filling the screen:**
The kiosk script auto-detects resolution via `xrandr` and passes `--window-size` to Chromium.
To check the detected resolution:
```bash
sudo -u kiosk DISPLAY=:0 XAUTHORITY=/home/kiosk/.Xauthority xrandr
```
To force a specific resolution, add to `/boot/firmware/config.txt`:
```ini
hdmi_group=2
hdmi_mode=82   # 1920x1080 60Hz
```
