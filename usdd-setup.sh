#!/usr/bin/env bash
# usdd-setup.sh — one-shot per-device bring-up for the USDD alert switcher.
#
# Run (as root) AFTER: `sudo bash install.sh`, a reboot, the capture board fitted,
# and the USDD power-cycled. It verifies the hardware, forces 1080p output, brings
# the capture pipeline up at 1080p30, starts the switcher, and captures the idle
# detection reference — stopping with a clear message if any step isn't right.
#
#   sudo usdd-setup.sh
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo usdd-setup.sh"; exit 1; }

hdr() { echo; echo "==> $*"; }
ok()  { echo "    [ OK ] $*"; }
die() { echo "    [FAIL] $*"; echo; exit 1; }

# --- 1. capture board present? (check the live media graph, not dmesg history) ---
hdr "1/4  Capture board"
MEDIA=""; for m in /dev/media*; do media-ctl -d "$m" -p 2>/dev/null | grep -q tc358743 && { MEDIA="$m"; break; }; done
[ -n "$MEDIA" ] || die "tc358743 not detected — CSI ribbon not seated. Power OFF, reseat both ends, reboot, retry."
SUB=$(media-ctl -d "$MEDIA" -e "tc358743 11-000f")
[ -n "$SUB" ] || die "could not resolve tc358743 subdev."
ok "board detected ($SUB)"

# --- 2. force 1080p output (idempotent) ---
hdr "2/4  1080p output"
if grep -q '^FORCE_RESOLUTION=' /boot/firmware/kiosk.conf; then
    ok "FORCE_RESOLUTION already set"
else
    echo 'FORCE_RESOLUTION="1920x1080"' >> /boot/firmware/kiosk.conf
    systemctl restart kiosk
    ok "set FORCE_RESOLUTION=1920x1080 and restarted the dashboard at 1080p"
fi

# --- 3. capture pipeline at 1080p30 ---
hdr "3/4  Capture pipeline (want 1080p30)"
systemctl restart usdd-capture-setup
sleep 3
PC=$(v4l2-ctl -d "$SUB" --query-dv-timings 2>/dev/null | awk '/Pixelclock/{print $2}')
[[ "${PC:-}" =~ ^[0-9]+$ ]] || PC=0
if [ "$PC" -ge 60000000 ] && [ "$PC" -le 80000000 ]; then
    ok "USDD locked at 1080p30"
elif [ "$PC" -ge 140000000 ]; then
    die "USDD is at 1080p60. Power-cycle the USDD device (it must re-read the EDID), wait ~45s, then re-run this script."
else
    die "No 1080p30 signal (pixelclock=$PC). Check the HDMI from the USDD, power-cycle the USDD, wait ~45s, re-run."
fi
systemctl restart usdd-switcher
sleep 2
systemctl is-active --quiet usdd-capture-setup && systemctl is-active --quiet usdd-switcher \
    || die "a service didn't come up — see: journalctl -u usdd-switcher -b"
ok "usdd-capture-setup and usdd-switcher are active"

# --- 4. idle reference ---
hdr "4/4  Calibrate idle reference"
echo "    The USDD must be showing its NORMAL IDLE screen right now (not an alert)."
read -r -p "    Press Enter to capture the idle reference (Ctrl-C to skip)... " _ || true
/usr/local/sbin/usdd-calibrate.sh idle || die "calibration failed (is the switcher producing frames?)."

echo
echo "==> Bring-up complete. Verify the takeover:"
echo "      sudo touch /run/usdd/force-alert    # TV takes over with the live USDD feed"
echo "      sudo rm  /run/usdd/force-alert       # returns to the dashboard"
echo "    Then reboot and confirm both services come up on their own."
