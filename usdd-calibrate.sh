#!/usr/bin/env bash
# usdd-calibrate.sh — capture the idle reference frame the switcher compares
# against, and read out the live difference so you can pick thresholds.
#
# Run on a Pi wired to a LIVE USDD (capture pipeline already up — i.e. after
# usdd-capture-setup has succeeded):
#
#   sudo usdd-calibrate.sh idle      # USDD on its normal IDLE screen -> saves reference
#   sudo usdd-calibrate.sh measure   # prints difference vs reference once per second
#                                    # -> fire a test alert and watch the number jump
#
# Then edit /boot/firmware/usdd.conf:
#   USDD_ON_THRESHOLD  a little BELOW the alert reading
#   USDD_OFF_THRESHOLD a little ABOVE the idle reading
# and: sudo systemctl restart usdd-switcher
set -uo pipefail
REF=/etc/usdd/idle.gray
GW=64; GH=36
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

grab() {  # write one GWxGH GRAY8 frame to $1
    gst-launch-1.0 -q v4l2src device=/dev/video0 num-buffers=1 \
        ! video/x-raw,format=BGR,width=1920,height=1080 \
        ! videoconvert ! videoscale \
        ! video/x-raw,format=GRAY8,width=$GW,height=$GH \
        ! filesink location="$1" >/dev/null 2>&1
}

case "${1:-}" in
  idle)
    mkdir -p /etc/usdd
    grab "$REF" || { echo "capture failed — is the pipeline up? (systemctl status usdd-capture-setup)"; exit 1; }
    sz=$(stat -c%s "$REF" 2>/dev/null || echo 0)
    echo "Saved idle reference -> $REF ($sz bytes; expected $((GW*GH)))."
    [ "$sz" -eq $((GW*GH)) ] || { echo "WARNING: unexpected size; capture may be wrong."; exit 1; }
    ;;
  measure)
    [ -f "$REF" ] || { echo "No reference yet — run: sudo $0 idle"; exit 1; }
    echo "Difference vs idle reference (Ctrl-C to stop). Fire a test alert and watch it jump:"
    while true; do
      grab "$TMP/cur.gray"
      python3 - "$REF" "$TMP/cur.gray" <<'PY'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
n=min(len(a),len(b)) or 1
print("  MAD = %5.1f" % (sum(abs(a[i]-b[i]) for i in range(n))/n))
PY
      sleep 1
    done
    ;;
  *)
    echo "Usage: sudo $0 {idle|measure}"; exit 1;;
esac
