#!/usr/bin/env bash
# install.sh - One-time setup for LJFD Kiosk Display on Raspberry Pi OS Lite.
# Run as root (or with sudo) on a fresh Pi OS Lite installation.
#
# What this script does:
#   1. Installs minimal X11 and Chromium packages
#   2. Creates a dedicated 'kiosk' user
#   3. Deploys kiosk.sh, kiosk.service, and kiosk.conf
#   4. Configures display, SSH, and power management
#   5. Enables the kiosk service

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK_USER="kiosk"
KIOSK_HOME="/home/$KIOSK_USER"

echo "=== LJFD Kiosk Display Setup ==="
echo ""

# --- Step 1: System update ---
echo "[1/7] Updating package lists..."
apt-get update -qq

# --- Step 2: Install minimal packages ---
echo "[2/7] Installing minimal X11 and Chromium packages..."

# Chromium package name varies: 'chromium-browser' (Bullseye) vs 'chromium' (Bookworm+)
# Use apt-get --simulate to check actual installability, not just metadata presence
if apt-get install --simulate chromium-browser &>/dev/null; then
    CHROMIUM_PKG="chromium-browser"
else
    CHROMIUM_PKG="chromium"
fi

apt-get install --no-install-recommends -y \
    xserver-xorg-core \
    xserver-xorg-legacy \
    xserver-xorg-input-libinput \
    xinit \
    x11-xserver-utils \
    xdotool \
    "$CHROMIUM_PKG"

# USDD capture-switcher dependencies (tc358743 HDMI-to-CSI2 -> dashboard/USDD switch)
apt-get install --no-install-recommends -y \
    v4l-utils \
    python3 \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad

# --- Step 3: Create kiosk user ---
echo "[3/7] Creating kiosk user..."
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G video,input,tty,render "$KIOSK_USER"
    echo "Created user: $KIOSK_USER"
else
    echo "User $KIOSK_USER already exists, skipping."
    usermod -aG video,input,tty,render "$KIOSK_USER"
fi

# --- Step 4: Deploy files ---
echo "[4/7] Deploying kiosk files..."

install -o "$KIOSK_USER" -g "$KIOSK_USER" -m 755 \
    "$SCRIPT_DIR/kiosk.sh" "$KIOSK_HOME/.xinitrc"

if [ ! -f /boot/firmware/kiosk.conf ]; then
    install -m 644 "$SCRIPT_DIR/kiosk.conf" /boot/firmware/kiosk.conf
    echo "Installed default kiosk.conf to /boot/firmware/"
else
    echo "kiosk.conf already exists on boot partition, not overwriting."
fi

install -m 644 "$SCRIPT_DIR/kiosk.service" /etc/systemd/system/kiosk.service
install -m 644 "$SCRIPT_DIR/kiosk-reboot.service" /etc/systemd/system/kiosk-reboot.service
install -m 644 "$SCRIPT_DIR/kiosk-reboot.timer" /etc/systemd/system/kiosk-reboot.timer
install -m 644 "$SCRIPT_DIR/kiosk-refresh.service" /etc/systemd/system/kiosk-refresh.service
install -m 644 "$SCRIPT_DIR/kiosk-refresh.timer" /etc/systemd/system/kiosk-refresh.timer

# Pi 5 has two DRM devices: V3D (3D-only, card0) and VC4 (display, card1).
# X picks the wrong one by default. Force modesetting driver on card1.
mkdir -p /etc/X11/xorg.conf.d
install -m 644 "$SCRIPT_DIR/10-modesetting.conf" /etc/X11/xorg.conf.d/10-modesetting.conf

# --- USDD capture switcher ---
echo "Deploying USDD capture switcher..."
install -d -m 755 /etc/usdd
install -m 644 "$SCRIPT_DIR/1080P30EDID.txt" /etc/usdd/1080P30EDID.txt
install -m 755 "$SCRIPT_DIR/usdd-capture-setup.sh" /usr/local/sbin/usdd-capture-setup.sh
install -m 755 "$SCRIPT_DIR/usdd-calibrate.sh" /usr/local/sbin/usdd-calibrate.sh
install -m 755 "$SCRIPT_DIR/usdd-switcher.py" /usr/local/bin/usdd-switcher.py
install -m 644 "$SCRIPT_DIR/usdd-capture-setup.service" /etc/systemd/system/usdd-capture-setup.service
install -m 644 "$SCRIPT_DIR/usdd-switcher.service" /etc/systemd/system/usdd-switcher.service

if [ ! -f /boot/firmware/usdd.conf ]; then
    install -m 644 "$SCRIPT_DIR/usdd.conf" /boot/firmware/usdd.conf
    echo "Installed default usdd.conf to /boot/firmware/"
else
    echo "usdd.conf already exists on boot partition, not overwriting."
fi

# tc358743 HDMI-to-CSI2 bridge overlay on the CAM/DISP1 connector (Pi 5)
CONFIG_TXT="/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ] && ! grep -q "dtoverlay=tc358743" "$CONFIG_TXT"; then
    printf '\n# LJFD USDD capture: HDMI-to-CSI2 bridge on CAM/DISP1 connector\ndtoverlay=tc358743,cam1\n' >> "$CONFIG_TXT"
    echo "Added dtoverlay=tc358743,cam1 to config.txt (reboot required)."
fi

touch /var/log/kiosk.log
chown "$KIOSK_USER":"$KIOSK_USER" /var/log/kiosk.log

# --- Step 5: Configure X server permissions ---
echo "[5/7] Configuring X server permissions..."
XWRAPPER_CONF="/etc/X11/Xwrapper.config"
cat > "$XWRAPPER_CONF" << 'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# --- Step 6: System configuration ---
echo "[6/7] Configuring system..."

# Disable getty on tty1 (kiosk.service takes over)
systemctl disable getty@tty1.service 2>/dev/null || true

# Enable SSH
systemctl enable ssh.service 2>/dev/null || true

# Disable Wi-Fi power management if NetworkManager is present
if [ -d /etc/NetworkManager/conf.d ]; then
    cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
fi

# Disable console blanking via kernel command line
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ] && ! grep -q "consoleblank=0" "$CMDLINE"; then
    sed -i 's/$/ consoleblank=0/' "$CMDLINE"
    echo "Added consoleblank=0 to kernel command line."
fi

# --- Step 7: Enable kiosk service and timers ---
echo "[7/7] Enabling kiosk service and timers..."
systemctl daemon-reload
systemctl enable kiosk.service
systemctl enable --now kiosk-reboot.timer
systemctl enable --now kiosk-refresh.timer

# USDD capture switcher (starts on next boot, after the tc358743 overlay loads)
systemctl enable usdd-capture-setup.service
systemctl enable usdd-switcher.service

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit /boot/firmware/kiosk.conf with your display URLs"
echo "  2. Reboot: sudo reboot"
echo ""
echo "The dashboard will start automatically on boot."
echo ""
echo "USDD alert switcher (only if a tc358743 HDMI-to-CSI2 board is fitted):"
echo "  - After reboot with a LIVE USDD wired in, calibrate detection:"
echo "      sudo usdd-calibrate.sh idle      # on the USDD idle screen"
echo "      sudo usdd-calibrate.sh measure   # fire a test alert, note the jump"
echo "    then set thresholds in /boot/firmware/usdd.conf and:"
echo "      sudo systemctl restart usdd-switcher"
echo "  - Bench test without an alert: sudo touch /run/usdd/force-alert (rm to hand back)"
echo ""
echo "SSH access remains available for remote management."
