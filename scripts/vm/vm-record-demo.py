#!/usr/bin/env python3
"""Record the README demo from OUTSIDE the guest, through the VM's VNC framebuffer (docs/testing-vm.md, "README demo
GIF"). Recording inside the guest (`screencapture -v`) makes macOS show its purple screen-recording indicator in the
menu bar; the VNC framebuffer has no such indicator.

  ~/.local/share/frost-vm/venv/bin/python -W ignore scripts/vm/vm-record-demo.py OUTDIR SNOWFLAKE_X SNOWFLAKE_Y TILE_X TILE_Y

Coordinates are guest points (global top-left origin); the VNC framebuffer is 2x. A drive thread moves the pointer
and clicks through VNC input (smooth glides at ~100 Hz, the snowflake click, a rest on the tile, the tile click, a
pause on the opened menu, Esc, the pointer glides away) while a second thread saves the top-right 480x328 pt region
as OUTDIR/f<n>.bmp at a fixed 25 fps from the client's framebuffer copy. The pointer is not part of the VNC framebuffer, so the
arrow is pasted into every frame from the position the drive thread last set (see ARROW). Convert with
ffmpeg (see docs/testing-vm.md).
"""
import os, re, sys, threading, time
from PIL import Image, ImageDraw
from twisted.internet import reactor
from vncdotool import api

out = sys.argv[1]
snow = (float(sys.argv[2]) * 2, float(sys.argv[3]) * 2)
tile = (float(sys.argv[4]) * 2, float(sys.argv[5]) * 2)
ITEM = (3000.0, 30.0)                       # where the forwarded item ends up (pointer left on it), pixels
X0, Y0, W, H = 2496, 0, 960, 656            # region in framebuffer pixels (top right 480x328 pt)
os.makedirs(out, exist_ok=True)
log = open(os.path.expanduser("~/.local/share/frost-vm/run.log")).read()
pw, port = re.findall(r"vnc://:([^@]*)@127\.0\.0\.1:(\d+)", log)[-1]
c = api.connect(f"127.0.0.1::{port}", password=pw)

# A macOS-like arrow (hot spot at its tip), drawn at 2x.
def make_arrow():
    pts = [(0, 0), (0, 34), (8, 27), (14, 40), (20, 37), (14, 25), (25, 25)]
    img = Image.new("RGBA", (30, 44), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.polygon([(x + 1, y + 1) for x, y in pts], fill=(255, 255, 255, 255))
    d.polygon([(x + 3, y + 5) for x, y in pts], fill=(0, 0, 0, 255))
    big = Image.new("RGBA", (30, 44), (0, 0, 0, 0))
    d2 = ImageDraw.Draw(big)
    d2.polygon(pts, fill=(255, 255, 255, 255))
    d2.polygon([(x + 3, y + 5) for x, y in [(0, 0), (0, 25), (6, 19), (11, 30), (14, 28), (10, 17), (18, 17)]], fill=(0, 0, 0, 255))
    return big
ARROW = make_arrow()

pointer = [2300.0, 900.0]
visible = [True]
stop = threading.Event()
t0 = time.time()

def move(x, y):
    pointer[0], pointer[1] = x, y
    c.mouseMove(int(x), int(y))

def glide(target, dur):
    fx, fy = pointer
    steps = max(2, int(dur * 100))
    for i in range(1, steps + 1):
        t = i / steps
        k = t * t * (3 - 2 * t)
        move(fx + (target[0] - fx) * k, fy + (target[1] - fy) * k)
        time.sleep(dur / steps)

def drive():
    time.sleep(1.0)
    move(*pointer); time.sleep(0.9)
    glide(snow, 0.9); time.sleep(0.25)
    c.mouseDown(1); time.sleep(0.07); c.mouseUp(1)
    time.sleep(1.0)
    glide((tile[0] + 60, tile[1] + 36), 0.5)
    glide(tile, 0.5); time.sleep(0.3)
    c.mouseDown(1); time.sleep(0.07); c.mouseUp(1)
    # Frost's click forwarding moves the real pointer onto the moved item and leaves it there; VNC doesn't know.
    time.sleep(0.2); pointer[0], pointer[1] = ITEM
    time.sleep(1.5)
    c.keyPress("esc"); time.sleep(0.6)
    glide((2300, 900), 0.7)
    time.sleep(3.2)
    stop.set()

def stream_updates():
    # Ask for the next incremental update after every update (inside the reactor thread), so protocol.screen stays
    # current without blocking the drive thread's calls (api calls from a pump thread serialize with them).
    p = c.protocol
    original = p.commitUpdate
    def commit(rectangles=None):
        original(rectangles)
        p.framebufferUpdateRequest(incremental=True)
    p.commitUpdate = commit
    reactor.callFromThread(lambda: p.framebufferUpdateRequest(incremental=True))

FPS = 25
c.refreshScreen()
stream_updates()
th = threading.Thread(target=drive, daemon=True); th.start()
n = 0
start = time.time()
while not stop.is_set():
    due = start + n / FPS
    time.sleep(max(0, due - time.time()))
    screen = c.protocol.screen
    img = screen.crop((X0, Y0, X0 + W, Y0 + H)).convert("RGBA")
    px, py = int(pointer[0] - X0), int(pointer[1] - Y0)
    if -30 < px < W and -44 < py < H:
        img.paste(ARROW, (px, py), ARROW)
    img.convert("RGB").save(os.path.join(out, f"f{n:05d}.bmp"))
    n += 1
th.join()
print(f"{n} frames in {time.time() - start:.1f}s ({FPS} fps target)", flush=True)
os._exit(0)
