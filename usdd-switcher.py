#!/usr/bin/env python3
"""usdd-switcher — take the TV over with the live USDD capture when its alert
screen appears, hand back to the kiosk dashboard when it clears.

Runs as the `kiosk` user in the X session (DISPLAY=:0). To avoid the video sink
placing its own window (which, with no window manager, maps off-position for a
moment before settling), the switcher **pre-creates** a fullscreen
override-redirect X window and hands its XID to the sink via GstVideoOverlay, so
the capture is correctly placed from the first frame. The window is unmapped
while idle (the Chromium dashboard shows through) and mapped during an alert.

One /dev/video0 owner at a time:
  IDLE  -> gst-launch subprocess: v4l2src ! (GRAY8 64x36) ! multifilesink   (detect only)
  ALERT -> in-process pipeline:   v4l2src ! tee ! <sink -> our window> + detect feed

Detection = mean-absolute-difference of the latest 64x36 GRAY8 frame vs a
calibrated idle reference. Config: /boot/firmware/usdd.conf.
Bench test: `sudo touch /run/usdd/force-alert` (rm to hand back).
"""
import os, sys, time, glob, signal, subprocess
import gi
gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import Gst, GstVideo  # noqa: E402  (GstVideo enables set_window_handle)
from Xlib import X, display as Xdisplay  # noqa: E402

CONF = "/boot/firmware/usdd.conf"
FRAMEDIR = "/run/usdd"
FORCE = os.path.join(FRAMEDIR, "force-alert")
GW, GH = 64, 36
GSIZE = GW * GH

SRC = ["v4l2src", "device=/dev/video0", "io-mode=mmap", "!",
       "video/x-raw,format=BGR,width=1920,height=1080"]


def log(msg):
    print(f"[usdd-switcher] {msg}", flush=True)


def load_conf():
    cfg = dict(ENABLED="1", ON_THRESHOLD="25", OFF_THRESHOLD="12",
               ON_DEBOUNCE="3", OFF_DEBOUNCE="6", MAX_ALERT_SEC="210",
               REFERENCE="/etc/usdd/idle.gray", FPS="2", SINK="ximagesink")
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("USDD_") and "=" in line:
                    k, v = line[5:].split("=", 1)
                    v = v.split("#", 1)[0]
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        log(f"{CONF} not found; using defaults")
    return cfg


def clear_frames():
    for f in glob.glob(f"{FRAMEDIR}/f*.gray"):
        try:
            os.remove(f)
        except OSError:
            pass


def start_idle(fps):
    """IDLE detection-only pipeline as a gst-launch subprocess (no display)."""
    clear_frames()
    cmd = ["gst-launch-1.0", "-q"] + SRC + [
        "!", "videorate", "!", f"video/x-raw,framerate={fps}/1",
        "!", "videoconvert", "!", "videoscale",
        "!", f"video/x-raw,format=GRAY8,width={GW},height={GH}",
        "!", "multifilesink", f"location={FRAMEDIR}/f%05d.gray",
        "max-files=4", "post-messages=false"]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, preexec_fn=os.setsid)


def stop_idle(p):
    if p and p.poll() is None:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            p.wait(timeout=5)
        except Exception:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except Exception:
                pass


def alert_pipeline_desc(fps, sink):
    """ALERT pipeline: display the capture (into our window) + tee a detect feed."""
    return (
        "v4l2src device=/dev/video0 io-mode=mmap ! "
        "video/x-raw,format=BGR,width=1920,height=1080 ! tee name=t "
        "t. ! queue max-size-buffers=3 leaky=downstream ! videoconvert ! "
        f"{sink} name=vsink force-aspect-ratio=false "
        "t. ! queue ! videorate ! video/x-raw,framerate={fps}/1 ! "
        "videoconvert ! videoscale ! "
        f"video/x-raw,format=GRAY8,width={GW},height={GH} ! "
        f"multifilesink location={FRAMEDIR}/f%05d.gray max-files=4 post-messages=false"
    ).format(fps=fps)


class Overlay:
    """A pre-created, correctly-placed fullscreen window the alert renders into."""

    def __init__(self):
        self.xdisp = Xdisplay.Display()
        s = self.xdisp.screen()
        self.w, self.h = s.width_in_pixels, s.height_in_pixels
        self.win = s.root.create_window(
            0, 0, self.w, self.h, 0, s.root_depth,
            X.InputOutput, X.CopyFromParent,
            background_pixel=s.black_pixel, override_redirect=1, event_mask=0)
        self.xid = int(self.win.id)
        self.xdisp.sync()          # window exists but is unmapped -> dashboard visible
        self.pipeline = None
        log(f"overlay window ready xid=0x{self.xid:x} ({self.w}x{self.h})")

    def _on_sync(self, bus, msg, *args):   # gi passes a user_data arg -> absorb it
        st = msg.get_structure()
        if st is not None and st.has_name("prepare-window-handle"):
            msg.src.set_window_handle(self.xid)
            try:
                msg.src.set_render_rectangle(0, 0, self.w, self.h)
            except Exception:
                pass
        return Gst.BusSyncReply.PASS

    def show(self, fps, sink):
        # The display can resize after we start (the kiosk applies FORCE_RESOLUTION
        # a few seconds into boot), so size the window to the CURRENT screen at alert
        # time — not whatever it was when __init__ ran. Otherwise a window created at
        # native 4K stays 4K on a 1080p screen and the video renders off-center.
        rg = self.xdisp.screen().root.get_geometry()
        self.w, self.h = rg.width, rg.height
        self.win.configure(x=0, y=0, width=self.w, height=self.h)
        self.win.map()
        self.win.configure(stack_mode=X.Above)   # newest map is on top anyway
        self.xdisp.sync()
        self.pipeline = Gst.parse_launch(alert_pipeline_desc(fps, sink))
        vsink = self.pipeline.get_by_name("vsink")
        # Belt and suspenders: set the handle now, and again via the sync handler
        # (some sinks only honour it when they emit prepare-window-handle).
        try:
            vsink.set_window_handle(self.xid)
        except Exception as e:
            log(f"set_window_handle (pre-play) failed: {e}")
        bus = self.pipeline.get_bus()
        try:
            bus.set_sync_handler(self._on_sync, None)
        except TypeError:
            bus.set_sync_handler(self._on_sync)
        self.pipeline.set_state(Gst.State.PLAYING)

    def hide(self):
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        self.win.unmap()
        self.xdisp.sync()

    def healthy(self):
        if self.pipeline is None:
            return False
        bus = self.pipeline.get_bus()
        while True:
            msg = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if msg is None:
                return True
            log(f"alert pipeline {msg.type.value_nicks}: "
                f"{msg.parse_error() if msg.type == Gst.MessageType.ERROR else 'eos'}")
            return False


def read_latest():
    for path in sorted(glob.glob(f"{FRAMEDIR}/f*.gray"), reverse=True):
        try:
            with open(path, "rb") as f:
                b = f.read()
            if len(b) == GSIZE:
                return b
        except OSError:
            continue
    return None


def mad(a, b):
    return sum(abs(a[i] - b[i]) for i in range(GSIZE)) / GSIZE


def main():
    os.makedirs(FRAMEDIR, exist_ok=True)
    Gst.init(None)
    cfg = load_conf()
    if cfg["ENABLED"] != "1":
        log("USDD_ENABLED=0; switcher idle. Exiting.")
        return

    fps, sink = cfg["FPS"], cfg["SINK"]
    on_t, off_t = float(cfg["ON_THRESHOLD"]), float(cfg["OFF_THRESHOLD"])
    on_d, off_d = int(cfg["ON_DEBOUNCE"]), int(cfg["OFF_DEBOUNCE"])
    max_alert = float(cfg["MAX_ALERT_SEC"])

    ref = None
    try:
        with open(cfg["REFERENCE"], "rb") as f:
            ref = f.read()
        if len(ref) != GSIZE:
            log(f"reference wrong size ({len(ref)}); ignoring"); ref = None
        else:
            log(f"loaded idle reference {cfg['REFERENCE']}")
    except OSError:
        log(f"no idle reference at {cfg['REFERENCE']} — run usdd-calibrate.sh. "
            "Only force-alert / timeout will switch.")

    overlay = Overlay()
    state = "IDLE"
    idle_proc = start_idle(fps)
    log(f"started in IDLE (dashboard); sink={sink} on={on_t} off={off_t}")
    over = under = 0
    alert_since = 0.0

    try:
        while True:
            time.sleep(0.5)
            forced = os.path.exists(FORCE)
            frame = read_latest()
            diff = mad(frame, ref) if (frame is not None and ref is not None) else None

            if state == "IDLE":
                if idle_proc.poll() is not None:
                    log("idle pipeline died; restarting")
                    time.sleep(0.5); idle_proc = start_idle(fps); continue
                hot = forced or (diff is not None and diff >= on_t)
                over = over + 1 if hot else 0
                if over >= (1 if forced else on_d):
                    log(f"ALERT onset (mad={diff}, forced={forced})")
                    stop_idle(idle_proc)
                    time.sleep(0.3)          # let /dev/video0 free before the alert pipeline
                    overlay.show(fps, sink)
                    state, alert_since, under = "ALERT", time.time(), 0
            else:  # ALERT
                if not overlay.healthy():
                    log("alert pipeline unhealthy; restarting it")
                    overlay.hide(); time.sleep(0.3); overlay.show(fps, sink)
                    continue
                cool = (diff is not None and diff <= off_t) if not forced else False
                under = under + 1 if cool else 0
                timed_out = (time.time() - alert_since) >= max_alert
                cleared_force = (not forced) and diff is None   # bench force removed
                if (under >= off_d) or timed_out or cleared_force:
                    log(f"hand back (mad={diff}, timeout={timed_out})")
                    overlay.hide()
                    time.sleep(0.3)
                    idle_proc = start_idle(fps)
                    state, over = "IDLE", 0
    except KeyboardInterrupt:
        pass
    finally:
        try:
            overlay.hide()
        except Exception:
            pass
        stop_idle(idle_proc)


if __name__ == "__main__":
    main()
