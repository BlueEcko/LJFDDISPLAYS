#!/usr/bin/env bash
# usdd-capture-setup.sh — bring up the tc358743 HDMI-to-CSI2 capture pipeline.
#
# Runs at boot (usdd-capture-setup.service), before usdd-switcher. It:
#   1. Locates the tc358743 media device + subdev (node numbers vary per boot).
#   2. Presents a 1080p30-only EDID so the USDD (an EDID-driven Broadcom/Pi source)
#      outputs 1920x1080p30 @ 74.25 MHz — under the tc358743 driver's 165 MHz cap.
#      A live USDD that has been running latches to its default 173 MHz CVT mode
#      and only re-reads the EDID on a real hot-plug, so we hold HPD low ~20 s.
#   3. Wires csi2 -> /dev/video0 as BGR3 1920x1080.
#
# Exit codes: 0 = pipeline ready; 2 = no lockable signal (USDD absent/over-cap).
set -uo pipefail

EDID_FILE="${USDD_EDID:-/etc/usdd/1080P30EDID.txt}"
log() { echo "[usdd-setup] $*"; }

# --- locate media device + entities (numbers renumber across boots) ---
MEDIA=""
for m in /dev/media*; do
    if media-ctl -d "$m" -p 2>/dev/null | grep -q tc358743; then MEDIA="$m"; break; fi
done
[ -z "$MEDIA" ] && { log "ERROR: tc358743 not found on any /dev/media*"; exit 1; }

ENTITY=$(media-ctl -d "$MEDIA" -p 2>/dev/null | grep -oE 'tc358743 [0-9]+-[0-9a-f]+' | head -n1)
SUBDEV=$(media-ctl -d "$MEDIA" -e "$ENTITY")
VIDNODE=$(media-ctl -d "$MEDIA" -e "rp1-cfe-csi2_ch0")
[ -z "$SUBDEV" ] && { log "ERROR: could not resolve tc358743 subdev"; exit 1; }
[ -z "$VIDNODE" ] && VIDNODE=/dev/video0
log "media=$MEDIA entity='$ENTITY' subdev=$SUBDEV video=$VIDNODE"

# "Locked" means a valid signal AT 1080p30 (pixel clock <= ~80 MHz). 1080p60
# (148.5 MHz) also locks under the driver's 165 MHz cap, but its bandwidth
# crashes streaming on the single CSI-2 lane — so we insist on 30 and force the
# HPD re-read otherwise (the USDD only honours our 1080p30-only EDID on a full
# hot-plug; a short --set-edid leaves it at 60).
locked() {
    local pc
    pc=$(v4l2-ctl -d "$SUBDEV" --query-dv-timings 2>/dev/null | awk '/Pixelclock/{print $2}')
    # Require ~1080p30 (60-80MHz). If the USDD refuses 30 and holds 60 (148.5MHz),
    # FAIL rather than configure/stream it — 1080p60 wedges the Pi on the 1-lane CSI.
    [ -n "$pc" ] && [ "$pc" -ge 60000000 ] && [ "$pc" -le 80000000 ]
}

# --- present EDID; force a full HPD cycle if the source is latched over-cap ---
# NEVER do a clear-edid / long-HPD "force re-read" automatically: it SEVERS this
# USDD's output and it won't recover without its own power-cycle. The USDD holds
# its mode across Pi reboots, so if a 1080p30 signal is already present, use it
# untouched. Only (re)present the EDID when there is no good signal — nothing to
# lose then, and it primes the EDID so the next USDD power-up selects 1080p30.
if ! locked; then
    log "no 1080p30 signal yet; presenting EDID (does not disturb a live signal)"
    v4l2-ctl -d "$SUBDEV" --set-edid=file="$EDID_FILE" >/dev/null 2>&1
    for _ in $(seq 1 10); do locked && break; sleep 1; done
fi
if ! locked; then
    log "ERROR: no 1080p30 signal. Power-cycle the USDD — it re-reads the EDID only on its own power-up."
    v4l2-ctl -d "$SUBDEV" --log-status >/dev/null 2>&1
    dmesg | grep -i 'Detected format' | tail -1 | sed 's/^/[usdd-setup] /'
    exit 2
fi
log "locked: $(v4l2-ctl -d "$SUBDEV" --query-dv-timings | grep -Ei 'width|height|frames' | tr '\n' ' ')"

# --- apply timings and wire the CSI-2 pipeline to the capture node ---
v4l2-ctl -d "$SUBDEV" --set-dv-bt-timings query >/dev/null
media-ctl -d "$MEDIA" -V '"csi2":0 [fmt:BGR888_1X24/1920x1080 field:none colorspace:srgb]'
media-ctl -d "$MEDIA" -V '"csi2":4 [fmt:BGR888_1X24/1920x1080 field:none colorspace:srgb]'
media-ctl -d "$MEDIA" -l '"csi2":4 -> "rp1-cfe-csi2_ch0":0 [1]'
v4l2-ctl -d "$VIDNODE" --set-fmt-video=width=1920,height=1080,pixelformat=BGR3 >/dev/null
log "pipeline ready on $VIDNODE (BGR3 1920x1080p30)"
