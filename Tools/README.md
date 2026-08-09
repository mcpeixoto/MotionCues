# Tools

Not part of the app. These generate the demo asset in `docs/`.

## What the demo asset is, and is not

**It is not a screen recording.** Capturing one needs macOS Screen Recording
permission, which was not available on the machine this was built on.

**It is the real pipeline, rendered offline.** `DemoRenderer` links the shipping
sources directly and drives them frame by frame:

| Piece | Source |
|---|---|
| Sensor samples | `SimulatedMotionProvider` — the app's own Simulator source, same misaligned sensor orientation, same band-limited road vibration |
| Reference frame, calibration, filtering | `MotionEngine` — untouched |
| Particles | `ParticleField` + `MetalDotRenderer` — the same field and the same shader the overlay uses, rendered to an offscreen texture instead of a window |
| Desktop behind the dots | **a static mockup**, `Backdrop/backdrop.html` |

So every dot position in `docs/demo.gif` is the genuine output of the shipping
code. The window, the code in it and the menu bar are a drawing.

It is deterministic — `SplitMix64` is seeded and frames step at a fixed `dt`
rather than off a display link — so re-running produces an identical sequence.

## Settings used

`Intensity: High` (1400 pt/s² per g, against a 900 default), particles slightly
larger and more opaque than default, so the field survives video compression.
Everything else is stock.

## Regenerating

```bash
# 1. Backdrop mockup → PNG (any Chromium will do)
"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  --headless --disable-gpu --hide-scrollbars --virtual-time-budget=2500 \
  --window-size=1470,956 --force-device-scale-factor=1 \
  --screenshot=Tools/Backdrop/backdrop-1x.png Tools/Backdrop/backdrop.html

# 2. Real engine + real renderer → PNG frames
xcodebuild -project MotionCues.xcodeproj -scheme DemoRenderer \
           -configuration Release -destination 'platform=macOS' build
DemoRenderer Tools/Backdrop/backdrop-1x.png /tmp/frames 24 30

# 3. Encode
ffmpeg -framerate 30 -i /tmp/frames/frame-%05d.png \
  -vf "scale=1280:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -crf 20 -preset slow -movflags +faststart demo.mp4

ffmpeg -framerate 30 -start_number 240 -i /tmp/frames/frame-%05d.png -frames:v 270 \
  -vf "fps=20,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  docs/demo.gif
```

`DemoRenderer` renders 26 seconds of warm-up before the first exported frame,
which is how long the calibration takes to converge — the same twenty-odd
seconds of driving the app asks a real user for.
